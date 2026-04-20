# frozen_string_literal: true

class Api::V1::SocialPostsController < ApplicationController
  before_action :set_company_scope
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

    post = @company.social_posts.new(permitted_params)
    post.created_by_user_id = current_user&.id
    post.status ||= 'draft'

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
  def update
    return unless authorize_action!('social_posts', 'update')

    if @post.update(permitted_params)
      render json: serialize(@post, detailed: true)
    else
      render json: { errors: @post.errors.full_messages }, status: :unprocessable_entity
    end
  end

  # DELETE /api/v1/social-posts/:id
  def destroy
    return unless authorize_action!('social_posts', 'delete')

    @post.update!(is_deleted: true)
    head :no_content
  end

  # POST /api/v1/social-posts/:id/approve
  def approve
    return unless authorize_action!('social_posts', 'update')

    unless @post.status == 'draft'
      return render json: { error: "Only draft posts can be approved (current: #{@post.status})" }, status: :unprocessable_entity
    end

    @post.update!(status: 'approved', nurture_approved: true)
    render json: serialize(@post, detailed: true)
  end

  # POST /api/v1/social-posts/:id/publish
  def publish
    return unless authorize_action!('social_posts', 'update')

    @post.update!(status: 'published', published_at: Time.current)

    # Fire explicit published webhook event
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
        intake_form_url: intake_form_url
      )
    rescue SocialPostGeneratorService::Error => e
      return render json: { error: e.message }, status: :unprocessable_entity
    end

    render json: result
  end

  # GET /api/v1/social-posts/stats
  def stats
    return unless authorize_action!('social_posts', 'read')
    render json: stats_payload(@company.social_posts.active)
  end

  private

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
      :ai_generation_version,
      image_urls: [],
      generation_context: {}
    )
  end

  def parse_time(value)
    return nil if value.blank?
    Time.zone.parse(value.to_s)
  rescue ArgumentError, TypeError
    nil
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
    form = @company.intake_forms.where(active: true).order(:id).first if @company.intake_forms.respond_to?(:where)
    form ||= @company.intake_forms.order(:id).first
    form&.public_url if form.respond_to?(:public_url)
  end

  def stats_payload(scope)
    {
      total:       scope.count,
      by_status:   scope.group(:status).count,
      by_platform: scope.group(:platform).count,
      by_intent:   scope.group(:intent_category).count,
      total_leads: scope.sum(:lead_count),
      total_deals: scope.sum(:deal_count),
      attributed_revenue: scope.sum(:attributed_revenue)
    }
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
      cta_type:           p.cta_type,
      scheduled_at:       p.scheduled_at,
      published_at:       p.published_at,
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
