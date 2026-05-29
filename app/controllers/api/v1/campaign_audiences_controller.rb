class Api::V1::CampaignAudiencesController < ApplicationController
  before_action :set_company_scope
  before_action :set_campaign

  def create
    return unless authorize_action!('campaigns', 'update')
    return render(json: { error: 'Campaign is locked. Pause it to edit.' }, status: :unprocessable_entity) unless editable?

    if @campaign.campaign_audience.present?
      return render(json: { error: 'Audience already exists. Use update instead.' }, status: :unprocessable_entity)
    end

    attrs = audience_params
    audience = @campaign.build_campaign_audience(
      source_type: attrs[:source_type],
      saved_audience_id: attrs[:saved_audience_id],
      filter_tree: attrs[:filter_tree] || {},
      exclude_filter_tree: attrs[:exclude_filter_tree] || {}
    )

    if audience.save
      recompute_estimate(audience)
      render json: audience_json(audience), status: :created
    else
      render json: { errors: audience.errors.full_messages }, status: :unprocessable_entity
    end
  end

  def update
    return unless authorize_action!('campaigns', 'update')
    return render(json: { error: 'Campaign is locked. Pause it to edit.' }, status: :unprocessable_entity) unless editable?

    audience = @campaign.campaign_audience
    return render(json: { error: 'No audience set' }, status: :unprocessable_entity) unless audience

    attrs = audience_params
    update_attrs = {}
    update_attrs[:filter_tree] = attrs[:filter_tree] if attrs.key?(:filter_tree)
    update_attrs[:exclude_filter_tree] = attrs[:exclude_filter_tree] if attrs.key?(:exclude_filter_tree)
    if attrs.key?(:exclude_active_campaign_enrollees)
      update_attrs[:exclude_active_campaign_enrollees] = ActiveModel::Type::Boolean.new.cast(attrs[:exclude_active_campaign_enrollees])
    end
    if attrs.key?(:exclude_active_nurture_enrollees)
      update_attrs[:exclude_active_nurture_enrollees] = ActiveModel::Type::Boolean.new.cast(attrs[:exclude_active_nurture_enrollees])
    end

    if audience.update(update_attrs)
      recompute_estimate(audience)
      render json: audience_json(audience)
    else
      render json: { errors: audience.errors.full_messages }, status: :unprocessable_entity
    end
  end

  def preview
    return unless authorize_action!('campaigns', 'read')

    audience = @campaign.campaign_audience
    source_type = params[:source_type].presence || audience&.source_type
    unless %w[Lead Contact Account].include?(source_type)
      return render(json: { error: 'Invalid source_type' }, status: :unprocessable_entity)
    end

    # Apply the actual filter (was returning the unfiltered company-wide total). Use the
    # passed-in filter if present (live editing), otherwise the saved audience's.
    filter_tree  = params[:filter_tree].present? ? to_unsafe(params[:filter_tree]) : (audience&.filter_tree || {})
    exclude_tree = params[:exclude_filter_tree].present? ? to_unsafe(params[:exclude_filter_tree]) : audience&.exclude_filter_tree

    scope = Audiences::FilterCompiler.new(
      company: @company, source_type: source_type,
      filter_tree: filter_tree, exclude_filter_tree: exclude_tree,
      exclude_active_campaign_enrollees: audience&.exclude_active_campaign_enrollees || false,
      exclude_active_nurture_enrollees: audience&.exclude_active_nurture_enrollees || false
    ).scope

    sample = scope.limit(20).map do |r|
      { id: r.id, name: record_display_name(r), email: record_email(r) }
    end
    render json: {
      count: scope.count,
      sample: sample,
      filter_evaluation: 'applied',
      channel: @campaign.channel,
      sms_opt_in_filter_active: @campaign.sms_channel? && !audience&.sms_compliance_override?,
      sms_compliance_override: audience&.sms_compliance_override? || false
    }
  rescue Audiences::FilterCompiler::CompilationError => e
    render json: { error: e.message }, status: :unprocessable_entity
  end

  def acknowledge_sms_compliance
    return unless authorize_action!('campaigns', 'update')
    audience = @campaign.campaign_audience
    return render(json: { error: 'No audience set' }, status: :unprocessable_entity) unless audience
    unless @campaign.sms_channel?
      return render(json: { error: 'Compliance acknowledgment only applies to SMS campaigns' }, status: :unprocessable_entity)
    end

    acknowledgment = (params[:acknowledgment] || '').to_s.strip
    unless acknowledgment.downcase.include?('have written consent')
      return render(json: { error: 'Acknowledgment must include the phrase "have written consent"' }, status: :unprocessable_entity)
    end

    meta = audience.metadata.is_a?(Hash) ? audience.metadata.deep_dup : {}
    meta['compliance_override_acknowledged'] = 'true'
    meta['compliance_override_user_id'] = current_user.id
    meta['compliance_override_at'] = Time.current.iso8601
    meta['compliance_override_acknowledgment_text'] = acknowledgment
    audience.update!(metadata: meta)

    CampaignEvent.create!(
      company_id: @company.id, campaign_id: @campaign.id,
      event_type: 'compliance_acknowledgment',
      occurred_at: Time.current,
      payload: {
        type: 'sms_opt_in_filter_removed',
        user_id: current_user.id,
        acknowledgment: acknowledgment,
        ip: request.remote_ip
      }
    )

    if defined?(WebhookService)
      WebhookService.fire(
        company_id: @company.id, event: 'campaign.compliance_acknowledged',
        payload: { campaign_id: @campaign.id, user_id: current_user.id, acknowledged_at: meta['compliance_override_at'] }
      )
    end

    render json: { success: true, acknowledged_at: meta['compliance_override_at'] }
  end

  def recompute
    return unless authorize_action!('campaigns', 'update')
    audience = @campaign.campaign_audience
    return render(json: { error: 'No audience set' }, status: :unprocessable_entity) unless audience

    # Use the same filtered FilterCompiler count as create/update — NOT a raw base.count,
    # which ignored the filter and reported the company's entire lead/contact/account total.
    recompute_estimate(audience)
    render json: { count: audience.estimated_count, estimated_at: audience.estimated_at }
  rescue Audiences::FilterCompiler::CompilationError => e
    render json: { error: e.message }, status: :unprocessable_entity
  end

  private

  def set_campaign
    @campaign = @company.campaigns.active.find(params[:campaign_id])
  rescue ActiveRecord::RecordNotFound
    render json: { error: 'Campaign not found' }, status: :not_found
  end

  def editable?
    %w[draft scheduled].include?(@campaign.status)
  end

  def audience_params
    params.require(:campaign_audience).permit(
      :source_type, :location_id, :saved_audience_id,
      :exclude_active_campaign_enrollees, :exclude_active_nurture_enrollees,
      filter_tree: {}, exclude_filter_tree: {}
    )
  end

  def to_unsafe(value)
    value.is_a?(ActionController::Parameters) ? value.to_unsafe_h : value
  end

  def recompute_estimate(audience)
    count = Audiences::FilterCompiler.new(
      company: @company,
      source_type: audience.source_type,
      filter_tree: audience.filter_tree,
      exclude_filter_tree: audience.exclude_filter_tree,
      exclude_active_campaign_enrollees: audience.exclude_active_campaign_enrollees,
      exclude_active_nurture_enrollees: audience.exclude_active_nurture_enrollees
    ).count
    audience.update!(estimated_count: count, estimated_at: Time.current)
  end

  def audience_json(audience)
    {
      id: audience.id,
      campaign_id: audience.campaign_id,
      source_type: audience.source_type,
      saved_audience_id: audience.saved_audience_id,
      filter_tree: audience.filter_tree,
      exclude_filter_tree: audience.exclude_filter_tree,
      exclude_active_campaign_enrollees: audience.exclude_active_campaign_enrollees,
      exclude_active_nurture_enrollees: audience.exclude_active_nurture_enrollees,
      estimated_count: audience.estimated_count,
      estimated_at: audience.estimated_at,
      metadata: audience.metadata
    }
  end

  def record_display_name(r)
    return "#{r.first_name} #{r.last_name}".strip if r.respond_to?(:first_name)
    return r.name if r.respond_to?(:name)
    "##{r.id}"
  end

  def record_email(r)
    r.respond_to?(:email) ? r.email : nil
  end
end
