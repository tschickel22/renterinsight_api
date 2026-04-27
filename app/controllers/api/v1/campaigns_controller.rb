class Api::V1::CampaignsController < ApplicationController
  before_action :set_company_scope
  before_action :set_campaign, only: %i[show update destroy duplicate start pause resume archive test_send preview stats]

  def index
    return unless authorize_action!('campaigns', 'read')

    @campaigns = @company.campaigns.active

    if params[:status].present?
      @campaigns = @campaigns.where(status: params[:status])
    end
    if params[:campaign_type].present?
      @campaigns = @campaigns.where(campaign_type: params[:campaign_type])
    end

    base_for_stats = @company.campaigns.active
    stats = {
      total: base_for_stats.count,
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

    if @campaign.save
      render json: campaign_json(@campaign, full: true), status: :created
    else
      render json: { errors: @campaign.errors.full_messages }, status: :unprocessable_entity
    end
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
      if @campaign.email_channel? && @campaign.resolve_email_connection.nil?
        reasons << 'Selected sender has no valid email connection. Connect an email account first.'
      end
      if @campaign.sms_channel? && @campaign.resolve_sms_sender.nil?
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

    step = @campaign.campaign_steps.active.ordered.first
    return render(json: { error: 'Campaign has no active steps' }, status: :unprocessable_entity) unless step

    if @campaign.email_channel?
      return render(json: { error: 'No valid email connection for this campaign' }, status: :unprocessable_entity) if @campaign.resolve_email_connection.nil?
      test_address = current_user.email
      return render(json: { error: 'Your user has no email on file for test send' }, status: :unprocessable_entity) if test_address.blank?
    else
      return render(json: { error: 'No active SMS number for this company' }, status: :unprocessable_entity) if @campaign.resolve_sms_sender.nil?
      test_address = current_user.try(:phone)
      return render(json: { error: 'Your user has no phone number on file for SMS test' }, status: :unprocessable_entity) if test_address.blank?
    end

    enrollment = CampaignEnrollment.find_or_initialize_by(
      campaign_id: @campaign.id, recipient_type: 'User', recipient_id: current_user.id
    )
    enrollment.assign_attributes(
      company_id: @company.id, status: 'pending', current_step_index: 0,
      email_address_snapshot: @campaign.email_channel? ? test_address : nil,
      sms_phone_snapshot: @campaign.sms_channel? ? test_address : nil,
      metadata: { 'test_send' => 'true', 'sent_by_user_id' => current_user.id }
    )
    enrollment.save!

    result = Campaigns::CampaignSender.new(enrollment: enrollment).deliver_current_step
    render json: { success: !!result, recipient: test_address, channel: @campaign.channel }
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

    base_url = ENV['CAMPAIGN_BASE_URL'].presence || 'https://app.renterinsight.com'

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

  def ai_generate
    return unless authorize_action!('campaigns', 'create')

    prompt = params[:prompt].to_s.strip
    return render(json: { error: 'prompt is required' }, status: :unprocessable_entity) if prompt.blank?
    channel = params[:channel].presence || 'email'

    generation = Campaigns::AiBuilder.new(company: @company, user: current_user).generate(
      prompt: prompt, channel: channel, context_overrides: params[:context_overrides].try(:to_unsafe_h) || {}
    )
    render json: {
      generation_id: generation.id, plan: generation.generated_plan,
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
    sender = {
      from_identity_type: params[:from_identity_type] || (plan_channel == 'sms' ? 'Company' : 'User'),
      from_identity_id: params[:from_identity_id] || (plan_channel == 'sms' ? @company.id : current_user.id),
      from_display_name: params[:from_display_name],
      location_id: params[:location_id]
    }

    campaign = Campaigns::AiBuilder.new(company: @company, user: current_user).accept(generation: generation, sender_params: sender)
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

    new_gen = Campaigns::AiBuilder.new(company: @company, user: current_user).refine(generation: generation, feedback: feedback)
    render json: { generation_id: new_gen.id, plan: new_gen.generated_plan, parent_id: generation.id }
  rescue Campaigns::AiBuilder::CreditLimitError => e
    render json: { error: e.message, code: 'credit_limit' }, status: :too_many_requests
  rescue Campaigns::AiBuilder::GenerationError => e
    render json: { error: e.message }, status: :unprocessable_entity
  end

  private

  def set_campaign
    @campaign = @company.campaigns.active.find(params[:id])
  rescue ActiveRecord::RecordNotFound
    render json: { error: 'Campaign not found' }, status: :not_found
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
      reply_to_address: c.reply_to_address,
      subject_default: c.subject_default,
      throttle_per_day: c.throttle_per_day,
      scheduled_at: c.scheduled_at,
      started_at: c.started_at,
      completed_at: c.completed_at,
      created_by_user_id: c.created_by_user_id,
      location_id: c.location_id,
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
      is_active: s.is_active
    }
  end

  def audience_json(a)
    {
      id: a.id,
      source_type: a.source_type,
      filter_tree: a.filter_tree,
      exclude_filter_tree: a.exclude_filter_tree,
      estimated_count: a.estimated_count,
      estimated_at: a.estimated_at
    }
  end
end
