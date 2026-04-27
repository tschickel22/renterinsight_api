class Api::V1::CampaignsController < ApplicationController
  before_action :set_company_scope
  before_action :set_campaign, only: %i[show update destroy duplicate start pause resume archive test_send preview stats ai_accept ai_refine]

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
    render json: campaign_json(@campaign, full: true)
  end

  def pause
    return unless authorize_action!('campaigns', 'update')
    return render(json: { error: "Cannot pause #{@campaign.status} campaign" }, status: :unprocessable_entity) unless %w[running scheduled].include?(@campaign.status)
    @campaign.update!(status: 'paused')
    render json: campaign_json(@campaign, full: true)
  end

  def resume
    return unless authorize_action!('campaigns', 'update')
    return render(json: { error: "Cannot resume #{@campaign.status} campaign" }, status: :unprocessable_entity) unless @campaign.status == 'paused'
    @campaign.update!(status: 'running')
    render json: campaign_json(@campaign, full: true)
  end

  def archive
    return unless authorize_action!('campaigns', 'update')
    @campaign.update!(status: 'archived')
    render json: campaign_json(@campaign, full: true)
  end

  def test_send
    return unless authorize_action!('campaigns', 'update')
    render json: { error: 'Test send will be available in Phase B', phase: 'A' }, status: :not_implemented
  end

  def preview
    return unless authorize_action!('campaigns', 'read')
    render json: { error: 'Preview rendering will be available in Phase B', phase: 'A' }, status: :not_implemented
  end

  def stats
    return unless authorize_action!('campaigns', 'read')
    render json: @campaign.stats_cache.presence || default_stats
  end

  def ai_generate
    return unless authorize_action!('campaigns', 'create')
    render json: { error: 'AI generation will be available in Phase B', phase: 'A' }, status: :not_implemented
  end

  def ai_accept
    return unless authorize_action!('campaigns', 'create')
    render json: { error: 'AI acceptance will be available in Phase B', phase: 'A' }, status: :not_implemented
  end

  def ai_refine
    return unless authorize_action!('campaigns', 'create')
    render json: { error: 'AI refinement will be available in Phase B', phase: 'A' }, status: :not_implemented
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
