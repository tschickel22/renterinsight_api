class Api::V1::CampaignsController < ApplicationController
  before_action :set_company_scope
  before_action :set_campaign, only: %i[show update destroy duplicate start pause resume archive test_send preview stats analytics_timeseries engagement engagement_by_step engagement_by_link audience_members exclude_audience_members]

  def index
    return unless authorize_action!('campaigns', 'read')

    @campaigns = @company.campaigns.active

    if params[:status].present?
      @campaigns = @campaigns.where(status: params[:status])
    else
      # Default view excludes archived to keep the list clean — archived
      # campaigns are still reachable via the explicit Archived filter.
      @campaigns = @campaigns.where.not(status: 'archived')
    end
    if params[:campaign_type].present?
      @campaigns = @campaigns.where(campaign_type: params[:campaign_type])
    end

    base_for_stats = @company.campaigns.active
    stats = {
      # "Total" backs the default (non-archived) view, so it excludes archived.
      total: base_for_stats.where.not(status: 'archived').count,
      draft: base_for_stats.where(status: 'draft').count,
      running: base_for_stats.where(status: 'running').count,
      paused: base_for_stats.where(status: 'paused').count,
      completed: base_for_stats.where(status: 'completed').count,
      archived: base_for_stats.where(status: 'archived').count
    }

    if params[:search].present?
      term = "%#{params[:search]}%"
      @campaigns = @campaigns.where('name ILIKE ? OR description ILIKE ?', term, term)
    end

    @campaigns = @campaigns.order(created_at: :desc)
    filtered_count = @campaigns.count

    page = (params[:page] || 1).to_i
    per_page = [(params[:per_page] || 50).to_i, 200].min
    @campaigns = @campaigns.offset((page - 1) * per_page).limit(per_page)

    render json: {
      items: @campaigns.map { |c| campaign_json(c) },
      meta: {
        total: filtered_count,
        page: page,
        per_page: per_page,
        total_pages: (filtered_count.to_f / per_page).ceil,
        stats: stats
      }
    }
  end

  def show
    return unless authorize_action!('campaigns', 'read')
    render json: campaign_json(@campaign, full: true)
  end

  def create
    return unless authorize_action!('campaigns', 'create')

    @campaign = @company.campaigns.build(campaign_params)
    @campaign.created_by_user_id = current_user.id

    ActiveRecord::Base.transaction do
      @campaign.save!

      if params[:campaign][:steps].present?
        params[:campaign][:steps].each do |step_param|
          sp = step_param.respond_to?(:to_unsafe_h) ? step_param.to_unsafe_h : step_param.to_h
          @campaign.campaign_steps.create!(
            position: sp['position'],
            wait_days: sp['wait_days'],
            wait_hours: sp['wait_hours'],
            channel: sp['channel'],
            subject: sp['subject'],
            preheader: sp['preheader'],
            body_blocks: sp['body_blocks'],
            sms_body: sp['sms_body'],
            media_url: sp['media_url'],
            is_active: true
          )
        end
      end

      audience_param = params[:campaign][:audience]
      if audience_param.present? && audience_param[:source_type].present?
        ap = audience_param.respond_to?(:to_unsafe_h) ? audience_param.to_unsafe_h : audience_param.to_h
        @campaign.create_campaign_audience!(
          source_type: ap['source_type'],
          filter_tree: ap['filter_tree'],
          additional_source_types: Array(ap['additional_source_types']).map(&:to_s).reject(&:blank?)
        )
      elsif saved_audience_id_param.present?
        apply_saved_audience(@campaign)
      end
    end

    render json: campaign_json(@campaign, full: true), status: :created
  rescue ActiveRecord::RecordInvalid => e
    render json: { errors: e.record.errors.full_messages }, status: :unprocessable_entity
  end

  def update
    return unless authorize_action!('campaigns', 'update')

    unless %w[draft scheduled].include?(@campaign.status)
      render json: { error: 'Most fields are locked once a campaign starts. Pause first to edit.' }, status: :unprocessable_entity
      return
    end

    if @campaign.update(campaign_params)
      render json: campaign_json(@campaign, full: true)
    else
      render json: { errors: @campaign.errors.full_messages }, status: :unprocessable_entity
    end
  end

  def destroy
    return unless authorize_action!('campaigns', 'delete')
    @campaign.update(is_deleted: true, status: 'archived')
    @campaign.campaign_enrollments.where(status: %w[pending active]).update_all(status: 'paused')
    head :no_content
  end

  # POST /api/v1/campaigns/:id/refine_with_ai
  # Sends the campaign's current plan back to Claude with additional
  # feedback so the admin can iterate on an EXISTING campaign (draft,
  # scheduled, paused) without cloning it. Only works when the campaign
  # was originally AI-generated — walks to the most recent generation in
  # the refine chain so subsequent refinements chain correctly. Applies
  # the resulting plan back to the campaign steps by index (preserves
  # cadence + timing set on the step rows).
  def refine_with_ai
    return unless authorize_action!('campaigns', 'update')

    unless %w[draft scheduled paused].include?(@campaign.status.to_s) ||
           (@campaign.status.to_s == 'completed' && @campaign.campaign_type.to_s == 'recurring_digest')
      return render(json: { error: "Cannot refine while status is #{@campaign.status}" }, status: :unprocessable_entity)
    end

    root_gen = @campaign.generated_from_ai_generation
    return render(json: { error: 'This campaign was not built by AI — use the step editor to change its content.' }, status: :unprocessable_entity) unless root_gen

    latest = latest_generation_in_chain(root_gen)

    feedback = params[:feedback].to_s.strip
    return render(json: { error: 'feedback is required' }, status: :unprocessable_entity) if feedback.blank?

    attachment_context = if params[:attachment_context].present?
                          Array(params[:attachment_context]).map { |a|
                            ac = a.respond_to?(:to_unsafe_h) ? a.to_unsafe_h : a.to_h
                            ac.stringify_keys
                          }
                        else
                          []
                        end

    new_gen = Campaigns::AiBuilder.new(company: @company, user: current_user, location: current_location).refine(
      generation: latest, feedback: feedback, attachment_context: attachment_context
    )

    apply_refined_plan_to_campaign!(@campaign, new_gen.generated_plan)

    render json: campaign_json(@campaign.reload, full: true)
  rescue Campaigns::AiBuilder::CreditLimitError => e
    render json: { error: e.message, code: 'credit_limit' }, status: :too_many_requests
  rescue Campaigns::AiBuilder::GenerationError => e
    render json: { error: e.message }, status: :unprocessable_entity
  rescue => e
    # Temporary diagnostic: include the top of the backtrace in the
    # response so the failing frame is visible in DevTools without
    # having to sift through Render logs.
    trace = Array(e.backtrace).grep(%r{/app/}).first(3)
    Rails.logger.error "[CampaignsController#refine_with_ai] #{e.class}: #{e.message}\n#{trace.join("\n")}"
    render json: { error: "#{e.class}: #{e.message}", trace: trace }, status: :unprocessable_entity
  end

  def duplicate
    return unless authorize_action!('campaigns', 'create')

    new_campaign = nil
    ActiveRecord::Base.transaction do
      new_campaign = @campaign.dup
      new_campaign.name = "(Copy) #{@campaign.name}"
      new_campaign.status = 'draft'
      new_campaign.started_at = nil
      new_campaign.completed_at = nil
      new_campaign.audience_snapshot_at = nil
      new_campaign.stats_cache = {}
      new_campaign.created_by_user_id = current_user.id
      new_campaign.save!

      @campaign.campaign_steps.each do |step|
        new_step = step.dup
        new_step.campaign_id = new_campaign.id
        new_step.save!
      end

      if @campaign.campaign_audience
        new_audience = @campaign.campaign_audience.dup
        new_audience.campaign_id = new_campaign.id
        new_audience.save!
      end
    end
    render json: campaign_json(new_campaign, full: true), status: :created
  end

  def start
    return unless authorize_action!('campaigns', 'update')

    unless @campaign.can_start?
      reasons = []
      reasons << 'Campaign must be in draft status' unless @campaign.status == 'draft'
      reasons << 'Campaign needs at least one active step' if @campaign.campaign_steps.where(is_active: true).empty?
      reasons << 'Campaign needs an audience' if @campaign.campaign_audience.nil?

      step_channels = @campaign.campaign_steps.active.pluck(:channel).compact.uniq
      needs_email = step_channels.include?('email') || (step_channels.empty? && @campaign.email_channel?)
      needs_sms = step_channels.include?('sms') || (step_channels.empty? && @campaign.sms_channel?)

      if needs_email && @campaign.resolve_email_connection_for_step.nil?
        reasons << 'Selected sender has no valid email connection. Connect an email account first.'
      end
      if needs_sms && @campaign.resolve_sms_sender_for_step.nil?
        reasons << 'No active SMS number for this company. Provision one in Settings > Communications > SMS.'
      end
      return render(json: { error: 'Cannot start campaign', reasons: reasons }, status: :unprocessable_entity)
    end

    new_status = (@campaign.scheduled_at.present? && @campaign.scheduled_at > Time.current) ? 'scheduled' : 'running'
    @campaign.update!(status: new_status, started_at: Time.current)

    if new_status == 'running' && defined?(WebhookService)
      WebhookService.fire(company_id: @company.id, event: 'campaign.started', payload: { campaign_id: @campaign.id })
      CampaignAudienceEnrollerJob.perform_later(@campaign.id) if defined?(CampaignAudienceEnrollerJob)
    end

    render json: campaign_json(@campaign, full: true)
  end

  def pause
    return unless authorize_action!('campaigns', 'update')
    return render(json: { error: "Cannot pause #{@campaign.status} campaign" }, status: :unprocessable_entity) unless %w[running scheduled].include?(@campaign.status)
    @campaign.update!(status: 'paused')
    if defined?(WebhookService)
      WebhookService.fire(company_id: @company.id, event: 'campaign.paused', payload: { campaign_id: @campaign.id })
    end
    render json: campaign_json(@campaign, full: true)
  end

  def resume
    return unless authorize_action!('campaigns', 'update')

    # Recurring-digest campaigns that landed as completed (pre-fix bug where
    # the scheduler finalized recurring campaigns missing a cron) can be
    # reactivated here — auto-heal the cron if blank and reschedule to the
    # next boundary. Paused campaigns resume to running as before.
    if @campaign.status == 'completed' && @campaign.campaign_type == 'recurring_digest'
      cron = @campaign.recurrence_cron.presence || '0 9 * * MON'
      @campaign.update!(recurrence_cron: cron)
      next_at = @campaign.next_recurrence_at
      if next_at.nil?
        return render(json: { error: 'Recurrence cron is invalid. Fix it in Settings and try again.' }, status: :unprocessable_entity)
      end
      @campaign.update!(
        status: 'scheduled',
        scheduled_at: next_at,
        completed_at: nil,
        audience_snapshot_at: nil
      )
      if defined?(WebhookService)
        WebhookService.fire(company_id: @company.id, event: 'campaign.resumed', payload: { campaign_id: @campaign.id, next_send_at: next_at.iso8601 })
      end
      return render json: campaign_json(@campaign, full: true)
    end

    return render(json: { error: "Cannot resume #{@campaign.status} campaign" }, status: :unprocessable_entity) unless @campaign.status == 'paused'
    @campaign.update!(status: 'running')
    if defined?(WebhookService)
      WebhookService.fire(company_id: @company.id, event: 'campaign.resumed', payload: { campaign_id: @campaign.id })
    end
    render json: campaign_json(@campaign, full: true)
  end

  def archive
    return unless authorize_action!('campaigns', 'update')
    @campaign.update!(status: 'archived')
    if defined?(WebhookService)
      WebhookService.fire(company_id: @company.id, event: 'campaign.archived', payload: { campaign_id: @campaign.id })
    end
    render json: campaign_json(@campaign, full: true)
  end

  def test_send
    return unless authorize_action!('campaigns', 'update')

    # Allow testing a specific step (defaults to first active step)
    step = if params[:step_id].present?
             @campaign.campaign_steps.active.find_by(id: params[:step_id])
           else
             @campaign.campaign_steps.active.ordered.first
           end
    return render(json: { error: 'Step not found or campaign has no active steps' }, status: :unprocessable_entity) unless step

    step_index = @campaign.campaign_steps.active.ordered.pluck(:id).index(step.id) || 0

    # Owner-mode campaigns resolve the sender per-recipient (each Lead/Contact/
    # Account's rep), so there's no campaign-wide connection to preflight.
    # For test sends we can't look up a real owner (the "recipient" is the
    # admin running the test), so we route the test through platform SES and
    # let the admin type any address they want to receive the test at.
    owner_mode = @campaign.try(:owner_identity?)

    if @campaign.email_channel?
      unless owner_mode
        return render(json: { error: 'No valid email connection for this campaign' }, status: :unprocessable_entity) if @campaign.resolve_email_connection.nil?
      end
      test_address = params[:test_email].to_s.strip.presence || current_user.email
      return render(json: { error: 'Enter a test email address' }, status: :unprocessable_entity) if test_address.blank?
    else
      return render(json: { error: 'No active SMS number for this company' }, status: :unprocessable_entity) if @campaign.resolve_sms_sender.nil?
      test_address = current_user.try(:phone)
      return render(json: { error: 'Your user has no phone number on file for SMS test' }, status: :unprocessable_entity) if test_address.blank?
    end

    metadata = { 'test_send' => 'true', 'sent_by_user_id' => current_user.id }
    # Signal to CampaignSender to skip the per-recipient owner resolution
    # and send via platform SES for this one enrollment. Only meaningful for
    # Owner-mode campaigns — everyone else already has a resolved connection.
    metadata['test_platform_send'] = 'true' if owner_mode && @campaign.email_channel?

    enrollment = CampaignEnrollment.find_or_initialize_by(
      campaign_id: @campaign.id, recipient_type: 'User', recipient_id: current_user.id
    )
    enrollment.assign_attributes(
      company_id: @company.id, status: 'pending', current_step_index: step_index,
      email_address_snapshot: @campaign.email_channel? ? test_address : nil,
      sms_phone_snapshot: @campaign.sms_channel? ? test_address : nil,
      metadata: metadata
    )
    enrollment.save!

    result = Campaigns::CampaignSender.new(enrollment: enrollment).deliver_current_step
    if result
      render json: { success: true, recipient: test_address, channel: @campaign.channel, step_position: step.position, step_subject: step.subject }
    else
      last_send = enrollment.campaign_sends.order(created_at: :desc).first
      err = last_send&.metadata.is_a?(Hash) ? last_send.metadata['error'] : nil
      render json: {
        success: false,
        recipient: test_address,
        channel: @campaign.channel,
        error: err.presence || 'Send failed (check email connection)'
      }
    end
  rescue => e
    Rails.logger.error "[CampaignsController#test_send] #{e.class}: #{e.message}"
    render json: { error: e.message }, status: :unprocessable_entity
  end

  def preview
    return unless authorize_action!('campaigns', 'read')
    step = @campaign.campaign_steps.active.ordered.first
    return render(json: { error: 'Campaign has no active steps' }, status: :unprocessable_entity) unless step

    recipient_type = params[:recipient_type] || 'Lead'
    recipient_id = params[:recipient_id]
    recipient = if recipient_id.present?
                  klass = recipient_type.safe_constantize
                  klass&.find_by(id: recipient_id)
                else
                  OpenStruct.new(
                    first_name: 'Sample', last_name: 'Recipient',
                    email: 'sample@example.com', phone: '+15555550100',
                    custom_field_values: {}
                  )
                end

    fake_send = CampaignSend.new(
      company_id: @company.id, campaign_id: @campaign.id,
      campaign_step_id: step.id, campaign_enrollment_id: 0
    )

    base_url = ENV['DMS_API_URL'].presence || ENV['CAMPAIGN_BASE_URL'].presence || 'https://renterinsight-api-staging.onrender.com'

    if @campaign.email_channel?
      rendered = Messaging::EmailRenderer.new(
        step: step, recipient: recipient, campaign: @campaign,
        campaign_send: fake_send, company: @company, base_url: base_url
      ).render
      render json: { channel: 'email', subject: rendered[:subject], html_body: rendered[:html_body], error: rendered[:error] }
    else
      rendered = Messaging::SmsRenderer.new(
        step: step, recipient: recipient, campaign: @campaign,
        campaign_send: fake_send, company: @company, base_url: base_url
      ).render
      render json: { channel: 'sms', body: rendered[:body], media_url: rendered[:media_url] }
    end
  rescue => e
    Rails.logger.error "[CampaignsController#preview] #{e.class}: #{e.message}"
    render json: { error: e.message }, status: :unprocessable_entity
  end

  def stats
    return unless authorize_action!('campaigns', 'read')
    render json: @campaign.stats_cache.presence || default_stats
  end

  def analytics_timeseries
    return unless authorize_action!('campaigns', 'read')
    days = params[:days].present? ? params[:days].to_i : Campaigns::AnalyticsTimeseries::DEFAULT_DAYS

    service = Campaigns::AnalyticsTimeseries.new(campaign: @campaign, days: days)
    render json: {
      campaign_id: @campaign.id,
      days: days,
      start_date: (Date.current - (days - 1).days).iso8601,
      end_date: Date.current.iso8601,
      buckets: service.buckets,
      totals: service.totals
    }
  end

  # GET /api/v1/campaigns/:id/engagement
  # Per-recipient engagement breakdown (opens/clicks/last activity/clicked links),
  # sortable by recent or most active — "who should I call next?".
  def engagement
    return unless authorize_action!('campaigns', 'read')

    result = Campaigns::RecipientEngagement.new(
      campaign:     @campaign,
      sort:         params[:sort],
      search:       params[:search],
      engaged_only: params[:engaged_only],
      page:         params[:page] || 1,
      per_page:     params[:per_page] || 50
    ).call

    render json: result
  end

  # GET /api/v1/campaigns/:id/engagement/by_step
  def engagement_by_step
    return unless authorize_action!('campaigns', 'read')
    render json: Campaigns::EngagementBreakdown.new(
      campaign: @campaign, sort: params[:sort],
      page: params[:page] || 1, per_page: params[:per_page] || 50
    ).by_step
  end

  # GET /api/v1/campaigns/:id/engagement/by_link
  def engagement_by_link
    return unless authorize_action!('campaigns', 'read')
    render json: Campaigns::EngagementBreakdown.new(
      campaign: @campaign, sort: params[:sort], step_id: params[:step_id], search: params[:search],
      page: params[:page] || 1, per_page: params[:per_page] || 50
    ).by_link
  end

  def ai_generate
    return unless authorize_action!('campaigns', 'create')

    prompt = params[:prompt].to_s.strip
    return render(json: { error: 'prompt is required' }, status: :unprocessable_entity) if prompt.blank?
    channel = params[:channel].presence || 'email'

    # Extract document context (base64-encoded files uploaded for AI to reference)
    attachment_context = if params[:attachment_context].present?
                           Array(params[:attachment_context]).map { |a|
                             ac = a.respond_to?(:to_unsafe_h) ? a.to_unsafe_h : a.to_h
                             ac.stringify_keys
                           }
                         else
                           []
                         end

    generation = Campaigns::AiBuilder.new(company: @company, user: current_user, location: current_location).generate(
      prompt: prompt, channel: channel,
      context_overrides: params[:context_overrides].try(:to_unsafe_h) || {},
      attachment_context: attachment_context
    )
    render json: {
      generation_id: generation.id, plan: generation.generated_plan,
      has_questions: generation.generated_plan['questions'].present?,
      model_version: generation.model_version,
      input_tokens: generation.input_tokens, output_tokens: generation.output_tokens
    }
  rescue Campaigns::AiBuilder::CreditLimitError => e
    render json: { error: e.message, code: 'credit_limit' }, status: :too_many_requests
  rescue Campaigns::AiBuilder::GenerationError => e
    render json: { error: e.message }, status: :unprocessable_entity
  end

  def ai_accept
    return unless authorize_action!('campaigns', 'create')

    generation = CampaignAiGeneration.find_by(id: params[:generation_id], company_id: @company.id)
    return render(json: { error: 'Generation not found' }, status: :not_found) unless generation

    plan_channel = generation.generated_plan['channel'] || 'email'
    from_type = params[:from_identity_type] || (plan_channel == 'sms' ? 'Company' : 'User')
    # Owner mode carries no fixed identity id — the sender resolves per
    # recipient at send time. Don't silently override with current_user.id
    # (that would turn the AI's Owner selection into a personal-mailbox
    # campaign without the admin noticing).
    from_id =
      if from_type == 'Owner'
        nil
      else
        params[:from_identity_id] || (plan_channel == 'sms' ? @company.id : current_user.id)
      end
    sender = {
      from_identity_type: from_type,
      from_identity_id: from_id,
      from_display_name: params[:from_display_name],
      location_id: params[:location_id]
    }

    plan_override = nil
    if params[:plan_override].present?
      plan_override = params[:plan_override].respond_to?(:to_unsafe_h) ? params[:plan_override].to_unsafe_h : params[:plan_override].to_h
    end

    campaign = Campaigns::AiBuilder.new(company: @company, user: current_user, location: current_location).accept(
      generation: generation, sender_params: sender, plan_override: plan_override
    )
    render json: { campaign_id: campaign.id, name: campaign.name, status: campaign.status }, status: :created
  rescue ActiveRecord::RecordInvalid => e
    render json: { errors: e.record.errors.full_messages }, status: :unprocessable_entity
  end

  def ai_refine
    return unless authorize_action!('campaigns', 'create')

    generation = CampaignAiGeneration.find_by(id: params[:generation_id], company_id: @company.id)
    return render(json: { error: 'Generation not found' }, status: :not_found) unless generation
    feedback = params[:feedback].to_s.strip
    return render(json: { error: 'feedback is required' }, status: :unprocessable_entity) if feedback.blank?

    # Pass document context for refine so AI retains knowledge of uploaded docs
    attachment_context = if params[:attachment_context].present?
                           Array(params[:attachment_context]).map { |a|
                             ac = a.respond_to?(:to_unsafe_h) ? a.to_unsafe_h : a.to_h
                             ac.stringify_keys
                           }
                         else
                           []
                         end

    new_gen = Campaigns::AiBuilder.new(company: @company, user: current_user, location: current_location).refine(
      generation: generation, feedback: feedback, attachment_context: attachment_context
    )
    render json: { generation_id: new_gen.id, plan: new_gen.generated_plan, has_questions: new_gen.generated_plan['questions'].present?, parent_id: generation.id }
  rescue Campaigns::AiBuilder::CreditLimitError => e
    render json: { error: e.message, code: 'credit_limit' }, status: :too_many_requests
  rescue Campaigns::AiBuilder::GenerationError => e
    render json: { error: e.message }, status: :unprocessable_entity
  end

  # GET /api/v1/campaigns/ai_generate/:generation_id/preview_render
  # Renders the AI-authored plan through the same EmailRenderer used at send
  # time — real inventory, real branding, placeholder recipient — so the
  # admin can see the finished email BEFORE accepting the generation. That
  # closes the "accepted the plan, then found out images were huge" loop.
  #
  # No specific recipient is used. MergeTagResolver's placeholder path
  # handles {{first_name}} etc. gracefully when recipient is nil.
  def ai_preview_render
    return unless authorize_action!('campaigns', 'read')

    generation = CampaignAiGeneration.find_by(id: params[:generation_id], company_id: @company.id)
    return render(json: { error: 'Generation not found' }, status: :not_found) unless generation

    plan = generation.generated_plan || {}
    step_plan = Array(plan['steps']).first
    return render(json: { error: 'Plan has no steps to preview' }, status: :unprocessable_entity) if step_plan.blank?

    # Un-persisted models so the preview doesn't leak into the campaigns
    # list, stats, or credit accounting. EmailRenderer treats
    # campaign_send.persisted? as the "render for real" signal.
    campaign = Campaign.new(
      company_id: @company.id,
      name: plan['name'] || 'AI Preview',
      channel: plan['channel'] || 'email',
      campaign_type: plan['campaign_type'] || 'drip',
      from_identity_type: 'Company',
      from_identity_id: nil,
      location_id: current_location&.id,
      status: 'draft'
    )
    # CampaignStep is company-scoped via its Campaign, not directly — the
    # step table has no company_id column. It has `position`, not
    # `step_number`. Setting either would raise UnknownAttributeError before
    # this endpoint could render.
    step = CampaignStep.new(
      position: 1,
      subject: step_plan['subject'],
      body_blocks: step_plan['body_blocks'] || [],
      inventory_block_config: step_plan['inventory_block_config']
    )
    fake_send = CampaignSend.new(company_id: @company.id, campaign_id: 0, campaign_step_id: 0, campaign_enrollment_id: 0)

    recipient = OpenStruct.new(
      first_name: 'Sample', last_name: 'Recipient',
      email: 'sample@example.com', phone: '+15555550100',
      custom_field_values: {}, location: current_location, owner_id: nil, owner: nil
    )

    base_url = ENV['DMS_API_URL'].presence || ENV['CAMPAIGN_BASE_URL'].presence || 'https://renterinsight-api-staging.onrender.com'
    rendered = Messaging::EmailRenderer.new(
      step: step, recipient: recipient, campaign: campaign,
      campaign_send: fake_send, company: @company, base_url: base_url
    ).render

    render json: {
      channel: 'email',
      subject: rendered[:subject],
      html_body: rendered[:html_body],
      error: rendered[:error]
    }
  rescue => e
    Rails.logger.error "[CampaignsController#ai_preview_render] #{e.class}: #{e.message}"
    render json: { error: e.message }, status: :unprocessable_entity
  end

  def merge_fields
    return unless authorize_action!('campaigns', 'read')
    source_type = params[:source_type].presence || 'Lead'
    channel = params[:channel].presence

    fields = Messaging::MergeFieldRegistry.for_source_type(source_type, channel: channel)
    grouped = Messaging::MergeFieldRegistry.grouped_for_source_type(source_type, channel: channel)

    render json: { source_type: source_type, channel: channel, fields: fields, grouped: grouped }
  end

  def audience_field_schema
    return unless authorize_action!('campaigns', 'read')
    source_type = params[:source_type].presence || 'Lead'

    render json: {
      source_type: source_type,
      fields: Audiences::FieldSchema.for_source_type(source_type),
      operator_labels: Audiences::FieldSchema.operators_with_labels
    }
  end

  def audience_members
    return unless authorize_action!('campaigns', 'read')

    ca = @campaign.campaign_audience
    return render(json: { error: 'No audience configured' }, status: :not_found) unless ca

    compiler = Audiences::FilterCompiler.new(
      company: @company,
      source_type: ca.source_type,
      filter_tree: ca.filter_tree,
      exclude_filter_tree: ca.exclude_filter_tree,
      exclude_active_campaign_enrollees: ca.try(:exclude_active_campaign_enrollees) || false,
      exclude_active_nurture_enrollees: ca.try(:exclude_active_nurture_enrollees) || false
    )
    scope = compiler.scope

    # Exclude manually excluded IDs
    excluded_ids = Array(ca.manual_exclude_ids).map(&:to_i).reject(&:zero?)
    scope = scope.where.not(id: excluded_ids) if excluded_ids.any?

    # Search
    if params[:search].present?
      term = '%' + params[:search] + '%'
      case ca.source_type
      when 'Lead', 'Contact'
        scope = scope.where('first_name ILIKE ? OR last_name ILIKE ? OR email ILIKE ? OR phone ILIKE ?', term, term, term, term)
      when 'Account'
        scope = scope.where('name ILIKE ? OR email ILIKE ? OR website ILIKE ?', term, term, term)
      end
    end

    total = scope.count
    page = (params[:page] || 1).to_i
    per_page = [(params[:per_page] || 25).to_i, 200].min
    records = scope.offset((page - 1) * per_page).limit(per_page).to_a

    enrollment_map = load_enrollment_data(records.map(&:id), ca.source_type)
    items = records.map { |r| campaign_member_row(r, ca.source_type, enrollment_map[r.id] || []) }

    render json: {
      items: items,
      meta: { total: total, page: page, per_page: per_page, total_pages: (total.to_f / per_page).ceil }
    }
  rescue Audiences::FilterCompiler::CompilationError => e
    render json: { error: e.message }, status: :unprocessable_entity
  end

  def exclude_audience_members
    return unless authorize_action!('campaigns', 'update')

    ca = @campaign.campaign_audience
    return render(json: { error: 'No audience configured' }, status: :not_found) unless ca

    ids = Array(params[:ids]).map(&:to_i).reject(&:zero?)
    return render(json: { error: 'ids required' }, status: :unprocessable_entity) if ids.empty?

    current_excludes = Array(ca.manual_exclude_ids).map(&:to_i)
    new_excludes = (current_excludes + ids).uniq

    ca.update!(manual_exclude_ids: new_excludes)

    # Recompute estimated count
    compiler = Audiences::FilterCompiler.new(
      company: @company, source_type: ca.source_type,
      filter_tree: ca.filter_tree, exclude_filter_tree: ca.exclude_filter_tree
    )
    excluded_scope = compiler.scope.where.not(id: new_excludes)
    ca.update_columns(estimated_count: excluded_scope.count, estimated_at: Time.current)

    render json: { success: true, excluded_count: new_excludes.size, estimated_count: excluded_scope.count }
  end

  private

  # Walks the parent_generation chain forward to the most recent descendant
  # so subsequent refines build on top of prior ones rather than starting
  # over from the original generation.
  def latest_generation_in_chain(root_gen)
    current = root_gen
    loop do
      next_gen = CampaignAiGeneration.where(parent_generation_id: current.id, company_id: @company.id).order(created_at: :desc).first
      break unless next_gen
      current = next_gen
    end
    current
  end

  # Applies a refined AI plan back to an existing campaign's steps in-place.
  # Matches by step index so cadence/timing set on the step rows survive the
  # refine — the AI's `wait_days` / `wait_hours` are respected only if the
  # existing row didn't already have one. Anything the AI didn't return
  # (missing step at index N) is left alone.
  def apply_refined_plan_to_campaign!(campaign, plan)
    steps_plan = Array(plan.is_a?(Hash) ? plan['steps'] : nil)
    # CampaignStep is ordered by `position` — there is no `step_number`
    # column. Ordering by a missing column raises ActiveRecord::StatementInvalid,
    # which fell out of the endpoint as a 500 with no user-visible message.
    existing_steps = campaign.campaign_steps.order(:position).to_a

    ActiveRecord::Base.transaction do
      steps_plan.each_with_index do |step_plan, idx|
        step = existing_steps[idx]
        next unless step
        attrs = {
          subject:              step_plan['subject'].presence || step.subject,
          preheader:            step_plan['preheader'].presence || step.preheader,
          body_blocks:          step_plan['body_blocks'] || step.body_blocks,
          sms_body:             step_plan['sms_body'].presence || step.sms_body,
          inventory_block_config: step_plan.key?('inventory_block_config') ? step_plan['inventory_block_config'] : step.inventory_block_config
        }
        step.update!(attrs.compact)
      end

      # Name and description are cheap to overwrite when the AI updated them.
      campaign_updates = {}
      campaign_updates[:name] = plan['name'] if plan['name'].present?
      campaign_updates[:description] = plan['description'] if plan['description'].present?
      campaign.update!(campaign_updates) if campaign_updates.any?
    end
  end

  def campaign_member_row(r, source_type, enrollments = [])
    base = case source_type
           when 'Lead'
             { id: r.id, first_name: r.first_name, last_name: r.last_name, title: r.try(:title), email: r.email, phone: r.phone, status: r.status, created_at: r.created_at }
           when 'Contact'
             { id: r.id, first_name: r.first_name, last_name: r.last_name, title: r.try(:title), email: r.email, phone: r.phone, account_id: r.try(:account_id), created_at: r.created_at }
           when 'Account'
             { id: r.id, name: r.name, account_type: r.account_type, email: r.email, website: r.website, created_at: r.created_at }
           else
             { id: r.id }
           end
    base.merge(last_activity_at: r.try(:last_activity_at), enrollments: enrollments)
  end

  # Batch-load active campaign + nurture enrollments for the given record ids,
  # keyed by record id, to avoid N+1 queries when building member rows.
  def load_enrollment_data(record_ids, source_type)
    return {} if record_ids.empty?

    result = Hash.new { |h, k| h[k] = [] }

    CampaignEnrollment
      .where(recipient_type: source_type, recipient_id: record_ids, status: %w[pending active])
      .includes(:campaign)
      .each do |ce|
        result[ce.recipient_id] << {
          type: 'campaign', id: ce.campaign_id,
          name: ce.campaign&.name || 'Unknown Campaign', status: ce.status
        }
      end

    nurture_scope =
      if source_type == 'Lead'
        # Legacy enrollments may use lead_id instead of the polymorphic enrollable.
        NurtureEnrollment
          .where(status: %w[idle running])
          .where('(enrollable_type = ? AND enrollable_id IN (?)) OR lead_id IN (?)', 'Lead', record_ids, record_ids)
          .includes(:nurture_sequence)
      else
        NurtureEnrollment
          .where(enrollable_type: source_type, enrollable_id: record_ids, status: %w[idle running])
          .includes(:nurture_sequence)
      end

    nurture_scope.each do |ne|
      entity_id = ne.enrollable_id || ne.lead_id
      next unless entity_id

      result[entity_id] << {
        type: 'nurture', id: ne.nurture_sequence_id,
        name: ne.nurture_sequence&.name || 'Unknown Sequence', status: ne.status
      }
    end

    result
  end

  def resolve_from_identity_name(c)
    case c.from_identity_type
    when 'User'
      u = User.find_by(id: c.from_identity_id)
      u ? [u.first_name, u.last_name].compact.join(' ').presence : nil
    when 'Location'
      Location.find_by(id: c.from_identity_id)&.name
    when 'Company'
      Company.find_by(id: c.from_identity_id)&.name
    when 'Owner'
      # Sender resolves per-recipient at send time; no single name to
      # show on the list view. FE renders a badge from the type instead.
      "Recipient's owner"
    end
  rescue => e
    Rails.logger.warn "[campaigns] resolve_from_identity_name: #{e.message}"
    nil
  end

  def set_campaign
    @campaign = @company.campaigns.active.find(params[:id])
  rescue ActiveRecord::RecordNotFound
    render json: { error: 'Campaign not found' }, status: :not_found
  end

  def apply_saved_audience(campaign)
    audience = @company.audiences.active.find_by(id: saved_audience_id_param)
    return unless audience

    campaign.create_campaign_audience!(
      source_type: audience.source_type,
      filter_tree: audience.filter_tree,
      exclude_filter_tree: audience.exclude_filter_tree,
      saved_audience_id: audience.id
    )
  end

  def saved_audience_id_param
    params[:saved_audience_id].presence || params.dig(:campaign, :saved_audience_id)
  end

  def campaign_params
    params.require(:campaign).permit(
      :name, :description, :campaign_type, :audience_mode, :channel,
      :from_identity_type, :from_identity_id, :from_display_name, :reply_to_address,
      :subject_default, :throttle_per_day,
      :utm_source, :utm_medium, :utm_campaign,
      :scheduled_at, :recurrence_cron,
      :location_id,
      goal_config: {}, reply_handling: {}, send_window: {}, trigger_config: {}
    )
  end

  def default_stats
    { total_sent: 0, delivered: 0, opened: 0, clicked: 0, replied: 0, bounced: 0, unsubscribed: 0, goals_met: 0 }
  end

  def campaign_json(c, full: false)
    base = {
      id: c.id,
      name: c.name,
      description: c.description,
      status: c.status,
      campaign_type: c.campaign_type,
      channel: c.channel,
      audience_mode: c.audience_mode,
      from_identity_type: c.from_identity_type,
      from_identity_id: c.from_identity_id,
      from_display_name: c.from_display_name,
      from_identity_name: resolve_from_identity_name(c),
      reply_to_address: c.reply_to_address,
      subject_default: c.subject_default,
      throttle_per_day: c.throttle_per_day,
      scheduled_at: c.scheduled_at,
      started_at: c.started_at,
      completed_at: c.completed_at,
      recurrence_cron: c.recurrence_cron,
      next_recurrence_at: c.try(:next_recurrence_at),
      created_by_user_id: c.created_by_user_id,
      location_id: c.location_id,
      generated_from_ai_generation_id: c.generated_from_ai_generation_id,
      created_at: c.created_at,
      updated_at: c.updated_at,
      stats_cache: c.stats_cache
    }
    return base unless full
    base.merge(
      goal_config: c.goal_config,
      reply_handling: c.reply_handling,
      send_window: c.send_window,
      trigger_config: c.trigger_config,
      utm_source: c.utm_source,
      utm_medium: c.utm_medium,
      utm_campaign: c.utm_campaign,
      steps: c.campaign_steps.ordered.map { |s| step_json(s) },
      audience: c.campaign_audience ? audience_json(c.campaign_audience) : nil,
      enrollments_count: c.campaign_enrollments.active.count
    )
  end

  def step_json(s)
    {
      id: s.id,
      position: s.position,
      channel: s.channel,
      wait_days: s.wait_days,
      wait_hours: s.wait_hours,
      subject: s.subject,
      preheader: s.preheader,
      body_blocks: s.body_blocks,
      sms_body: s.sms_body,
      media_url: s.media_url,
      inventory_block_config: s.inventory_block_config,
      attachments: Array(s.attachments),
      is_active: s.is_active
    }
  end

  def audience_json(a)
    {
      id: a.id,
      source_type: a.source_type,
      additional_source_types: Array(a.try(:additional_source_types)),
      filter_tree: a.filter_tree,
      exclude_filter_tree: a.exclude_filter_tree,
      estimated_count: a.estimated_count,
      estimated_at: a.estimated_at,
      exclude_active_campaign_enrollees: a.try(:exclude_active_campaign_enrollees) || false,
      exclude_active_nurture_enrollees: a.try(:exclude_active_nurture_enrollees) || false
    }
  end
end
