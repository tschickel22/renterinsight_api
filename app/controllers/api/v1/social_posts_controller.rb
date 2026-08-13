# frozen_string_literal: true

class Api::V1::SocialPostsController < ApplicationController
  skip_before_action :authenticate, only: [:skip, :email_approve, :email_decline]
  before_action :set_company_scope, except: [:skip, :email_approve, :email_decline]
  before_action :set_post, only: %i[show update destroy approve publish schedule duplicate]

  MAX_PER_PAGE = 200

  # GET /api/v1/social-posts
  def index
    return unless authorize_action!('social_posts', 'read')

    scope = @company.social_posts.active

    scope = scope.where(status: params[:status])                     if params[:status].present?
    scope = scope.where(platform: params[:platform])                 if params[:platform].present?
    scope = scope.where(intent_category: params[:intent_category])   if params[:intent_category].present?
    scope = scope.where(created_by_user_id: params[:created_by_user_id]) if params[:created_by_user_id].present?
    scope = scope.where(vehicle_id: params[:vehicle_id])             if params[:vehicle_id].present?
    scope = scope.where('created_at >= ?', parse_time(params[:from])) if params[:from].present?
    scope = scope.where('created_at <= ?', parse_time(params[:to]))   if params[:to].present?

    if (q = params[:q].to_s.strip).present?
      like = "%#{q}%"
      scope = scope.where('caption ILIKE ? OR headline ILIKE ? OR description ILIKE ?', like, like, like)
    end

    filtered_count = scope.count
    page     = [(params[:page] || 1).to_i, 1].max
    per_page = [[((params[:per_page] || 50).to_i), MAX_PER_PAGE].min, 1].max

    posts = scope.order(created_at: :desc).offset((page - 1) * per_page).limit(per_page)

    render json: {
      social_posts: posts.map { |p| serialize(p) },
      meta: {
        total:       filtered_count,
        page:        page,
        per_page:    per_page,
        total_pages: (filtered_count.to_f / per_page).ceil,
        stats:       stats_payload(@company.social_posts.active)
      }
    }
  end

  # GET /api/v1/social-posts/:id
  def show
    return unless authorize_action!('social_posts', 'read')
    render json: serialize(@post, detailed: true)
  end

  # POST /api/v1/social-posts
  def create
    return unless authorize_action!('social_posts', 'create')

    post = @company.social_posts.new(permitted_params.except(:hashtags))
    post.created_by_user_id = current_user&.id

    # Store hashtags in generation_context if provided
    if params[:social_post][:hashtags].present?
      ctx = (post.generation_context || {}).deep_stringify_keys
      ctx['hashtags'] = Array(params[:social_post][:hashtags])
      post.generation_context = ctx
    end

    post.status ||= auto_approve_on_create?(post) ? 'approved' : 'draft'

    if post.status == 'approved'
      post.approved_at    = Time.current
      post.approved_by_id = current_user&.id
    end

    if post.save
      # Auto-set utm_content + tagged_url after we have an id
      post.update_columns(
        utm_content: post.utm_content.presence || post.id.to_s,
        tagged_url:  build_tagged_url(post)
      )
      render json: serialize(post, detailed: true), status: :created
    else
      render json: { errors: post.errors.full_messages }, status: :unprocessable_entity
    end
  end

  # PATCH/PUT /api/v1/social-posts/:id
  #
  # Once a post is published it is a live object on the Page as well as a row
  # here, so an edit has to reach the Page or not happen at all. A local-only
  # edit leaves our copy asserting something the Page does not say, with
  # nothing in the UI to reveal the drift.
  #
  # Graph only lets us change the message, so attachments are frozen after
  # publish and the caller is told to delete and repost instead.
  def update
    return unless authorize_action!('social_posts', 'update')

    caption_before = build_post_caption(@post)

    # hashtags has no column — it lives inside generation_context (mirrors #create)
    @post.assign_attributes(permitted_params.except(:hashtags))

    if params[:social_post].key?(:hashtags)
      ctx = (@post.generation_context || {}).deep_stringify_keys
      ctx['hashtags'] = Array(params[:social_post][:hashtags])
      @post.generation_context = ctx
    end

    if live_on_platform?(@post)
      frozen = frozen_attachment_changes(@post)
      if frozen.any?
        return render json: {
          error: "The #{frozen.to_sentence} of a published post cannot be changed. Delete this post and create a new one."
        }, status: :unprocessable_entity
      end

      # Only reach out when the text the Page is showing actually changed —
      # editing bookkeeping fields (vehicle, utm_campaign) must not need a
      # round trip, or a photo post could never be re-tagged.
      caption_after = build_post_caption(@post)
      if caption_after != caption_before
        result = push_caption_to_platform(@post, caption_after)
        return render json: { error: result[:error] }, status: :unprocessable_entity unless result[:ok]
      end
    end

    if @post.save
      render json: serialize(@post, detailed: true)
    else
      render json: { errors: @post.errors.full_messages }, status: :unprocessable_entity
    end
  end

  # DELETE /api/v1/social-posts/:id
  #
  # A published post lives on the Page too, and removing only our row leaves it
  # up on Facebook while it vanishes from the app — the reporter deleted a test
  # post here and it stayed live there. So the remote delete has to succeed
  # before we soft-delete.
  #
  # `force=true` is the deliberate override for the cases the API cannot cover:
  # the post was already removed by hand on Facebook, the page is disconnected
  # for good, or it is an Instagram post (which Graph cannot delete at all).
  def destroy
    return unless authorize_action!('social_posts', 'delete')

    result = delete_remote_post(@post)

    if result && !result[:ok] && !truthy_param?(params[:force])
      return render json: {
        error:                result[:error],
        remote_delete_failed: true
      }, status: :unprocessable_entity
    end

    @post.update!(is_deleted: true)
    head :no_content
  end

  # POST /api/v1/social-posts/:id/approve
  def approve
    return unless authorize_action!('social_posts', 'update')

    unless @post.status == 'draft'
      return render json: { error: "Post must be in draft status to approve (current: #{@post.status})" }, status: :unprocessable_entity
    end

    @post.update!(
      status:           'approved',
      nurture_approved: true,
      approved_at:      Time.current,
      approved_by_id:   current_user&.id
    )
    render json: serialize(@post, detailed: true)
  end

  # POST /api/v1/social-posts/:id/publish
  # Doubles as "repost" for a previously failed post — re-running this on a
  # `failed` post retries the publish and clears the stored failure on success.
  def publish
    return unless authorize_action!('social_posts', 'update')

    if @post.status == 'published'
      return render json: { error: 'This post has already been published.' }, status: :unprocessable_entity
    end

    integration = FacebookIntegration.current_for(@company)
    unless integration
      return render json: { error: 'No Facebook page connected. Go to Settings > Integrations to connect.' }, status: :unprocessable_entity
    end

    begin
      result =
        if @post.platform.to_s == 'instagram'
          # Instagram video is Reels — a separate flow with its own rules.
          if @post.video_url.present?
            return render json: { error: 'Instagram video posting is not supported yet. Publish this to Facebook instead.' }, status: :unprocessable_entity
          end

          image_url = Array(@post.image_urls).first
          return render json: { error: 'Instagram posts require at least one image.' }, status: :unprocessable_entity if image_url.blank?

          ig_account_id = integration.metadata.to_h.deep_stringify_keys['instagram_business_account_id']
          return render json: { error: 'No Instagram Business Account linked. Connect Instagram in Settings.' }, status: :unprocessable_entity if ig_account_id.blank?

          MetaGraphApi.publish_instagram_post(
            ig_account_id,
            integration.page_access_token,
            caption:   build_post_caption(@post),
            image_url: image_url
          )
        elsif @post.video_url.present?
          # Facebook can't mix a video with photos, so video wins outright.
          MetaGraphApi.publish_page_video(
            integration.page_id,
            integration.page_access_token,
            message:   build_post_caption(@post),
            video_url: @post.video_url
          )
        else
          # More than one image publishes as a carousel; same permission.
          images = Array(@post.image_urls).map { |u| u.to_s.strip }.reject(&:blank?)

          if images.length > 1
            MetaGraphApi.publish_page_carousel(
              integration.page_id,
              integration.page_access_token,
              message:    build_post_caption(@post),
              image_urls: images,
              link:       @post.tagged_url
            )
          else
            MetaGraphApi.publish_page_post(
              integration.page_id,
              integration.page_access_token,
              message:   build_post_caption(@post),
              link:      @post.tagged_url,
              photo_url: images.first
            )
          end
        end
    rescue MetaGraphApi::ExpiredTokenError => _e
      integration.update(status: 'expired')
      msg = 'Facebook token expired. Please reconnect in Settings > Integrations.'
      mark_publish_failed(@post, reason: 'expired_token', error: msg)
      return render json: { error: msg, failure_reason: msg }, status: :unprocessable_entity
    rescue MetaGraphApi::Error => e
      msg = "Facebook API error: #{e.message}"
      mark_publish_failed(@post, reason: 'meta_api_error', error: msg)
      return render json: { error: msg, failure_reason: msg }, status: :unprocessable_entity
    end

    external_id = MetaGraphApi.published_post_id(result)

    @post.update!(
      status:             'published',
      published_at:       Time.current,
      external_post_id:   external_id,
      generation_context: clear_publish_failure(@post)
    )

    fire_published_webhook(@post)

    render json: serialize(@post, detailed: true)
  end

  # POST /api/v1/social-posts/:id/schedule
  def schedule
    return unless authorize_action!('social_posts', 'update')

    scheduled_at = parse_time(params[:scheduled_at])
    return render json: { error: 'scheduled_at required' }, status: :bad_request if scheduled_at.blank?
    return render json: { error: 'scheduled_at must be in the future' }, status: :unprocessable_entity if scheduled_at <= Time.current

    @post.update!(scheduled_at: scheduled_at, status: 'scheduled')
    render json: serialize(@post, detailed: true)
  end

  # POST /api/v1/social-posts/:id/duplicate
  def duplicate
    return unless authorize_action!('social_posts', 'create')

    copy = @post.dup
    copy.assign_attributes(
      status:              'draft',
      published_at:        nil,
      scheduled_at:        nil,
      external_post_id:    nil,
      lead_count:          0,
      deal_count:          0,
      attributed_revenue:  0,
      reach:               nil,
      impressions:         nil,
      engagement_count:    nil,
      link_clicks:         nil,
      metrics_synced_at:   nil,
      nurture_approved:    false,
      created_by_user_id:  current_user&.id,
      utm_content:         nil,
      tagged_url:          nil
    )
    copy.save!
    copy.update_columns(
      utm_content: copy.id.to_s,
      tagged_url:  build_tagged_url(copy)
    )
    render json: serialize(copy, detailed: true), status: :created
  end

  # POST /api/v1/social-posts/generate
  def generate
    return unless authorize_action!('social_posts', 'create')

    intent_category = params[:intent_category].to_s
    post_type       = params[:post_type].to_s.presence || 'company_page'
    platform        = params[:platform].to_s.presence  || 'facebook'
    tone            = params[:tone].to_s.presence      || 'friendly'
    topic_details   = params[:topic_details].to_s.presence
    intake_form_url = params[:intake_form_url].to_s.presence

    return render json: { error: 'intent_category required' }, status: :bad_request if intent_category.blank?

    vehicle = if params[:vehicle_id].present?
      @company.vehicles.where(is_deleted: false).find_by(id: params[:vehicle_id])
    end

    image_urls = Array(params[:image_urls]).map(&:to_s).select(&:present?)
    current_draft = if params[:current_draft].respond_to?(:permit)
      params[:current_draft].permit(:caption, :headline, :description, :cta_type, hashtags: []).to_h
    end

    begin
      result = SocialPostGeneratorService.generate(
        company:         @company,
        intent_category: intent_category,
        post_type:       post_type,
        platform:        platform,
        vehicle:         vehicle,
        user:            current_user,
        tone:            tone,
        topic_details:   topic_details,
        intake_form_url: intake_form_url,
        image_urls:      image_urls,
        current_draft:   current_draft
      )
    rescue SocialPostGeneratorService::Error => e
      return render json: { error: e.message }, status: :unprocessable_entity
    end

    render json: result
  end

  # GET /api/v1/social-posts/intent_options
  # Returns the intent set + default rotation appropriate for this company's
  # industry, so the frontend doesn't hardcode dealer-only intents.
  def intent_options
    return unless authorize_action!('social_posts', 'read')

    profile = SocialPostIntentCatalog.for_company(@company)
    render json: {
      industry:         @company.try(:industry),
      family:           profile.family.to_s,
      subject_label:    subject_label_for(profile),
      default_rotation: profile.default_rotation,
      requires_subject: profile.family == :dealer,
      # The tenant's own logo, offered in the composer as an opt-in fallback when
      # a post has no image. Deliberately the company logo and not the platform
      # brand — a dealership's post must never carry DealerTide's mark.
      logo_url:           @company.try(:logo).presence,
      inventory_statuses: Vehicle::STATUSES,
      intents: profile.intents.map do |i|
        { value: i.value, label: i.label, cta: i.cta, requires_subject: i.requires_subject }
      end
    }
  end

  # GET /api/v1/social-posts/stats
  def stats
    return unless authorize_action!('social_posts', 'read')
    render json: stats_payload(@company.social_posts.active)
  end

  # GET /api/v1/social-posts/seasonal_suggestions
  def seasonal_suggestions
    return unless authorize_action!('social_posts', 'read')
    render json: {
      current: SeasonalContentService.current_suggestions.map { |e|
        { name: e.name, intent: e.intent, topic: e.topic, icon: e.icon,
          month: e.month, day_start: e.day_start, day_end: e.day_end }
      },
      calendar: SeasonalContentService.full_calendar
    }
  end

  # GET /api/v1/social-posts/:id/skip?token=...
  # Token-signed link from approval email. No session auth required.
  # GET /api/v1/social-posts/:id/skip  (token-based, no auth)
  def skip
    payload = SocialPostMailer.decode_action_token(params[:token].to_s)
    return render json: { error: 'Invalid or expired token' }, status: :unauthorized if payload.blank?
    return render json: { error: 'Token does not match post' }, status: :unauthorized unless payload['post_id'].to_i == params[:id].to_i
    return render json: { error: 'Token is not a skip token' }, status: :unauthorized unless payload['action'].to_s == 'skip'

    post = SocialPost.active.find_by(id: params[:id])
    return render json: { error: 'Post not found' }, status: :not_found unless post
    return render json: { message: 'Post already actioned', status: post.status }, status: :ok if post.status != 'draft'

    post.update!(status: 'failed', nurture_approved: false)
    render json: { message: 'Post skipped', status: post.status }
  end

  # GET /api/v1/social-posts/:id/email_approve  (token-based, no auth)
  def email_approve
    payload = SocialPostMailer.decode_action_token(params[:token].to_s)
    return render_email_action_page('Invalid or expired link.', error: true) if payload.blank?
    return render_email_action_page('Token does not match this post.', error: true) unless payload['post_id'].to_i == params[:id].to_i
    return render_email_action_page('Invalid action token.', error: true) unless payload['action'].to_s == 'approve'

    post = SocialPost.active.find_by(id: params[:id])
    return render_email_action_page('Post not found.', error: true) unless post
    return render_email_action_page("This post has already been #{post.status}.", already: true) unless post.status == 'draft'

    post.update!(status: 'approved', approved_at: Time.current, nurture_approved: true)
    PublishSocialPostJob.perform_later(post.id) if defined?(PublishSocialPostJob)
    render_email_action_page(
      'Post approved and publishing!',
      success: true,
      note: "It may take up to 5 minutes to appear on #{post.platform.to_s.titleize}. You can close this tab."
    )
  end

  # GET /api/v1/social-posts/:id/email_decline  (token-based, no auth)
  def email_decline
    payload = SocialPostMailer.decode_action_token(params[:token].to_s)
    return render_email_action_page('Invalid or expired link.', error: true) if payload.blank?
    return render_email_action_page('Token does not match this post.', error: true) unless payload['post_id'].to_i == params[:id].to_i
    return render_email_action_page('Invalid action token.', error: true) unless payload['action'].to_s == 'decline'

    post = SocialPost.active.find_by(id: params[:id])
    return render_email_action_page('Post not found.', error: true) unless post
    return render_email_action_page("This post has already been #{post.status}.", already: true) unless post.status == 'draft'

    post.update!(status: 'failed', nurture_approved: false)
    render_email_action_page('Post declined.', declined: true)
  end

  private

  def render_email_action_page(message, success: false, error: false, declined: false, already: false, note: nil)
    icon = success ? '✅' : error ? '❌' : declined ? '🚫' : 'ℹ️'
    bg   = success ? '#dcfce7' : error ? '#fee2e2' : declined ? '#fff7ed' : '#dbeafe'
    sub  = note.presence || 'You can close this tab.'
    html = <<~HTML
      <!DOCTYPE html><html><head><meta charset="UTF-8"><title>Social Post Action</title>
      <meta name="viewport" content="width=device-width, initial-scale=1">
      <style>
        body{font-family:-apple-system,Arial,sans-serif;display:flex;justify-content:center;align-items:center;min-height:100vh;background:#{bg};margin:0}
        .card{background:white;border-radius:12px;padding:48px 40px;max-width:420px;text-align:center;box-shadow:0 4px 12px rgba(0,0,0,.08)}
        .icon{font-size:48px;margin-bottom:16px}
        .msg{font-size:18px;color:#111827;font-weight:600}
        .sub{font-size:14px;color:#6b7280;margin-top:12px}
      </style></head>
      <body><div class="card">
        <div class="icon">#{icon}</div>
        <div class="msg">#{ERB::Util.html_escape(message)}</div>
        <div class="sub">#{ERB::Util.html_escape(sub)}</div>
      </div></body></html>
    HTML
    render html: html.html_safe, layout: false
  end

  def set_post
    @post = @company.social_posts.active.find_by(id: params[:id])
    render json: { error: 'Not found' }, status: :not_found unless @post
  end

  def permitted_params
    params.require(:social_post).permit(
      :location_id, :social_account_id, :vehicle_id,
      :post_type, :intent_category, :platform, :status,
      :caption, :headline, :description, :cta_type,
      :tagged_url, :utm_campaign, :utm_content,
      :scheduled_at, :nurture_approved, :nurture_sequence_id,
      :ai_generation_version, :video_url,
      image_urls: [],
      hashtags: [],
      generation_context: {}
    )
  end

  def parse_time(value)
    return nil if value.blank?
    Time.zone.parse(value.to_s)
  rescue ArgumentError, TypeError
    nil
  end

  # Should a newly-created post skip draft and go straight to approved?
  # Rule 1: rep_personal posts never need approval.
  # Rule 2: users with social_posts:update permission ARE the approver.
  def auto_approve_on_create?(post)
    return true if post.post_type.to_s == 'rep_personal'
    can?('social_posts', 'update')
  end

  # Concatenate caption + hashtags for outbound posting.
  # Hashtags live inside generation_context since there is no dedicated column.
  def build_post_caption(post)
    parts = []
    parts << post.caption if post.caption.present?

    tags = extract_hashtags(post)
    parts << tags.map { |h| "##{h.to_s.delete('#').strip}" }.reject(&:empty?).join(' ') if tags.any?
    parts.join("\n\n")
  end

  def extract_hashtags(post)
    raw = post.generation_context.is_a?(Hash) ? post.generation_context.deep_stringify_keys['hashtags'] : nil
    return Array(raw) if raw.is_a?(Array)
    return JSON.parse(raw) if raw.is_a?(String) && raw.strip.start_with?('[')
    []
  rescue JSON::ParserError
    []
  end

  def build_tagged_url(post)
    base = company_intake_form_url(post)
    return nil if base.blank?

    uri = URI.parse(base)
    existing = URI.decode_www_form(uri.query.to_s).to_h

    merged = existing.merge(
      'utm_source'   => (post.platform || 'facebook').to_s,
      'utm_medium'   => 'social',
      'utm_campaign' => (post.utm_campaign.presence || post.intent_category).to_s,
      'utm_content'  => post.utm_content.presence || post.id.to_s
    ).reject { |_, v| v.to_s.blank? }

    uri.query = URI.encode_www_form(merged)
    uri.to_s
  rescue URI::InvalidURIError
    nil
  end

  def company_intake_form_url(post)
    form = @company.intake_forms.where(is_active: true).order(:id).first if @company.intake_forms.respond_to?(:where)
    form ||= @company.intake_forms.order(:id).first
    form&.public_url if form.respond_to?(:public_url)
  end

  def stats_payload(scope)
    {
      # "Total Posts" means posts that exist as real output — scheduled,
      # published, or failed in the attempt. Drafts are work in progress, not
      # posts, and auto-generated ones piled up fast enough to make this tile
      # meaningless. They still have their own tile via by_status.
      total:       scope.where.not(status: 'draft').count,
      by_status:   scope.group(:status).count,
      by_platform: scope.group(:platform).count,
      by_intent:   scope.group(:intent_category).count,
      total_leads: scope.sum(:lead_count),
      total_deals: scope.sum(:deal_count),
      attributed_revenue: scope.sum(:attributed_revenue)
    }
  end

  # What this tenant calls the thing a post can be about.
  #
  # The intent catalog only knows the broad family, so every dealer got the
  # generic 'unit', which the composer rendered as "Vehicle". A manufactured
  # housing dealer sells homes, and the label system already says so: the
  # 'vehicle' key resolves to "Home" for that industry, and a tenant can
  # override it under Settings > Labels. Use that rather than a second,
  # disagreeing name for the same thing.
  #
  # Non-dealer families keep the catalog's wording ("product or feature",
  # "offering"), which has no inventory behind it to label.
  def subject_label_for(profile)
    return profile.subject_label unless profile.family == :dealer
    return profile.subject_label unless @company.respond_to?(:resolved_labels)

    @company.resolved_labels['vehicle'].presence || profile.subject_label
  end

  # ------------------------------------------------------------------
  # Keeping a published post and the live Page post in step
  # ------------------------------------------------------------------

  # Attributes that describe the attachment Facebook has already rendered.
  # Graph cannot change any of them after publish, so an edit that touches one
  # is a request we have to refuse rather than silently apply locally.
  IMMUTABLE_ONCE_PUBLISHED = {
    'image_urls' => 'images',
    'video_url'  => 'video',
    'platform'   => 'platform',
    'tagged_url' => 'link'
  }.freeze

  # Is there a real post on the platform behind this row?
  def live_on_platform?(post)
    post.status.to_s == 'published' && post.external_post_id.present?
  end

  # Dirty tracking alone is too eager here. The compose form re-sends the whole
  # payload on every save, so a post stored with a NULL image_urls comes back as
  # [] and reads as "changed" — which would refuse a plain caption edit on a
  # text post. Only a real difference should block.
  def frozen_attachment_changes(post)
    IMMUTABLE_ONCE_PUBLISHED.filter_map do |attr, label|
      next unless post.changed.include?(attr)

      before, after = post.changes[attr]
      next if normalized_attachment(before) == normalized_attachment(after)

      label
    end
  end

  # nil, [], and [''] all describe a post with no attachment.
  def normalized_attachment(value)
    case value
    when nil   then nil
    when Array then value.map { |v| v.to_s.strip }.reject(&:blank?).presence
    else value.to_s.strip.presence
    end
  end

  # A post published through /feed — no photo, no video. It is the only shape
  # whose message Graph will edit, and the only one where external_post_id is a
  # story id rather than a photo id.
  def plain_feed_post?(post)
    post.video_url.blank? &&
      Array(post.image_urls).map { |u| u.to_s.strip }.reject(&:blank?).empty?
  end

  # Push an edited caption to the live post. Returns {ok:} / {ok:, error:}
  # rather than raising so the caller can refuse the save cleanly.
  def push_caption_to_platform(post, caption)
    if post.platform.to_s == 'instagram'
      return { ok: false, error: 'Instagram does not allow editing a published post through its API. Delete this post and create a new one.' }
    end

    unless plain_feed_post?(post)
      return { ok: false, error: 'Facebook does not allow editing the text of a published post that has a photo or video. Delete this post and create a new one.' }
    end

    integration = FacebookIntegration.current_for(@company)
    return { ok: false, error: 'No Facebook page connected, so the live post cannot be updated. Reconnect in Settings > Integrations.' } unless integration

    MetaGraphApi.update_page_post_message(
      post.external_post_id,
      integration.page_access_token,
      message: caption
    )
    { ok: true }
  rescue MetaGraphApi::ExpiredTokenError
    integration&.update(status: 'expired')
    { ok: false, error: 'Facebook token expired. Please reconnect in Settings > Integrations.' }
  rescue MetaGraphApi::NotFoundError
    { ok: false, error: 'That post no longer exists on Facebook. It may have been deleted there already.' }
  rescue MetaGraphApi::Error => e
    { ok: false, error: "Facebook rejected the edit: #{e.message}" }
  end

  # Remove the live post from the platform. Returns nil when there is nothing
  # out there to remove (a draft, or a publish that never got an id), which the
  # caller reads as "just soft-delete".
  def delete_remote_post(post)
    return nil unless live_on_platform?(post)

    if post.platform.to_s == 'instagram'
      return { ok: false, error: 'Instagram does not allow deleting a post through its API. Remove it in the Instagram app first, then delete it here.' }
    end

    integration = FacebookIntegration.current_for(@company)
    return { ok: false, error: 'No Facebook page connected, so the live post cannot be removed. Reconnect in Settings > Integrations.' } unless integration

    MetaGraphApi.delete_page_post(post.external_post_id, integration.page_access_token)
    { ok: true }
  rescue MetaGraphApi::NotFoundError
    # Already gone on Facebook — somebody deleted it there by hand. The two
    # sides agree, so this is a success, not something to make the user force.
    { ok: true }
  rescue MetaGraphApi::ExpiredTokenError
    integration&.update(status: 'expired')
    { ok: false, error: 'Facebook token expired, so the live post could not be removed. Reconnect in Settings > Integrations.' }
  rescue MetaGraphApi::Error => e
    { ok: false, error: "Facebook refused to delete the post: #{e.message}" }
  end

  def truthy_param?(value)
    ActiveModel::Type::Boolean.new.cast(value) == true
  end

  # Persist a publish failure (status + human-readable reason) so the UI can
  # show why it failed and offer a repost. Mirrors PublishSocialPostJob#mark_failed.
  def mark_publish_failed(post, reason:, error:)
    ctx = post.generation_context.is_a?(Hash) ? post.generation_context.deep_stringify_keys : {}
    post.update!(
      status:             'failed',
      generation_context: ctx.merge(
        'publish_failure' => {
          'reason'    => reason,
          'error'     => error,
          'failed_at' => Time.current.iso8601
        }
      )
    )
  end

  # Return generation_context with any stale publish_failure removed (used after
  # a successful repost so the old error doesn't linger on a now-published post).
  def clear_publish_failure(post)
    ctx = post.generation_context.is_a?(Hash) ? post.generation_context.deep_stringify_keys : {}
    ctx.except('publish_failure')
  end

  def publish_failure_for(post)
    ctx = post.generation_context
    return nil unless ctx.is_a?(Hash)
    pf = ctx.deep_stringify_keys['publish_failure']
    pf.is_a?(Hash) ? pf : nil
  end

  def fire_published_webhook(post)
    return unless defined?(WebhookService)

    WebhookService.fire(
      company_id: post.company_id,
      event:      'social_post.published',
      payload: {
        id:              post.id,
        platform:        post.platform,
        intent_category: post.intent_category,
        post_type:       post.post_type,
        headline:        post.headline,
        caption:         post.caption,
        published_at:    post.published_at,
        external_post_id: post.external_post_id
      }
    )
  rescue => e
    Rails.logger.error "[SocialPosts#publish] webhook fire failed: #{e.message}"
  end

  def serialize(p, detailed: false)
    base = {
      id:                 p.id,
      post_type:          p.post_type,
      intent_category:    p.intent_category,
      platform:           p.platform,
      status:             p.status,
      caption:            p.caption,
      headline:           p.headline,
      image_urls:         p.image_urls,
      video_url:          p.video_url,
      cta_type:           p.cta_type,
      scheduled_at:       p.scheduled_at,
      published_at:       p.published_at,
      approved_at:        p.approved_at,
      approved_by_id:     p.approved_by_id,
      lead_count:         p.lead_count,
      deal_count:         p.deal_count,
      attributed_revenue: p.attributed_revenue,
      vehicle_id:         p.vehicle_id,
      created_by_user_id: p.created_by_user_id,
      social_account_id:  p.social_account_id,
      utm_campaign:       p.utm_campaign,
      utm_content:        p.utm_content,
      tagged_url:         p.tagged_url,
      created_at:         p.created_at,
      updated_at:         p.updated_at
    }

    # Surface publish-failure details on every view (list + detail) so the UI can
    # show the reason and offer a repost on failed posts.
    if (pf = publish_failure_for(p))
      base[:failure_reason]   = pf['error']
      base[:failure_category] = pf['reason']
      base[:failed_at]        = pf['failed_at']
    end

    if detailed
      base.merge!(
        description:         p.description,
        reach:               p.reach,
        impressions:         p.impressions,
        engagement_count:    p.engagement_count,
        link_clicks:         p.link_clicks,
        metrics_synced_at:   p.metrics_synced_at,
        nurture_approved:    p.nurture_approved,
        nurture_sequence_id: p.nurture_sequence_id,
        generation_context:  p.generation_context,
        ai_generation_version: p.ai_generation_version,
        vehicle:             serialize_vehicle(p.vehicle),
        created_by_user:     serialize_user(p.created_by_user),
        social_account:      serialize_account(p.social_account)
      )
    end
    base
  end

  def serialize_vehicle(v)
    return nil unless v
    {
      id: v.id, year: v.year, make: v.make, model: v.model,
      bedrooms: v.bedrooms, bathrooms: v.bathrooms,
      sale_price: v.sale_price, photo_url: v.photo_url,
      stock_number: v.stock_number, status: v.status
    }
  end

  def serialize_user(u)
    return nil unless u
    { id: u.id, first_name: u.first_name, last_name: u.last_name, email: u.email }
  end

  def serialize_account(a)
    return nil unless a
    { id: a.id, platform: a.platform, name: a.name, status: a.status }
  end
end
