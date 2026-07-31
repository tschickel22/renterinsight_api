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

    # Selecting a saved audience (no inline definition): adopt its source_type + filters so
    # the campaign audience matches it. Explicit params still win.
    saved = (@company.audiences.find_by(id: attrs[:saved_audience_id]) if attrs[:saved_audience_id].present?)
    audience = @campaign.build_campaign_audience(
      source_type:         attrs[:source_type].presence || saved&.source_type,
      saved_audience_id:   attrs[:saved_audience_id],
      filter_tree:         attrs[:filter_tree] || saved&.filter_tree || {},
      exclude_filter_tree: attrs[:exclude_filter_tree] || saved&.exclude_filter_tree || {},
      additional_source_types: normalize_additional_source_types(attrs[:additional_source_types])
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

    # Selecting a saved audience must adopt ITS source_type + filters, otherwise a Lead
    # audience's filter (e.g. last_activity_at) lands on a Contact campaign audience and the
    # FilterCompiler rejects the field. When saved_audience_id is provided, copy from it.
    if attrs.key?(:saved_audience_id)
      update_attrs[:saved_audience_id] = attrs[:saved_audience_id]
      if attrs[:saved_audience_id].present? && (saved = @company.audiences.find_by(id: attrs[:saved_audience_id]))
        update_attrs[:source_type] = saved.source_type
        update_attrs[:filter_tree] = saved.filter_tree
        update_attrs[:exclude_filter_tree] = saved.exclude_filter_tree
      end
    end

    # Explicit values still override (inline edits after selecting).
    update_attrs[:source_type] = attrs[:source_type] if attrs.key?(:source_type)
    update_attrs[:filter_tree] = attrs[:filter_tree] if attrs.key?(:filter_tree)
    update_attrs[:exclude_filter_tree] = attrs[:exclude_filter_tree] if attrs.key?(:exclude_filter_tree)
    if attrs.key?(:exclude_active_campaign_enrollees)
      update_attrs[:exclude_active_campaign_enrollees] = ActiveModel::Type::Boolean.new.cast(attrs[:exclude_active_campaign_enrollees])
    end
    if attrs.key?(:exclude_active_nurture_enrollees)
      update_attrs[:exclude_active_nurture_enrollees] = ActiveModel::Type::Boolean.new.cast(attrs[:exclude_active_nurture_enrollees])
    end
    if attrs.key?(:additional_source_types)
      update_attrs[:additional_source_types] = normalize_additional_source_types(attrs[:additional_source_types])
    end

    if audience.update(update_attrs)
      recompute_estimate(audience)
      enroll_new_matches
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
      manual_exclude_ids: audience&.manual_exclude_ids,
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
    enroll_new_matches
    render json: { count: audience.estimated_count, estimated_at: audience.estimated_at }
  rescue Audiences::FilterCompiler::CompilationError => e
    render json: { error: e.message }, status: :unprocessable_entity
  end

  private

  # Recalculating only ever rewrote estimated_count, so a widened audience on a
  # live dynamic campaign showed the new recipients on screen while none of them
  # got an enrollment row — and therefore no email. Enroll them here so the number
  # the user just saw is backed by real enrollments. No-op while the campaign is
  # paused (the enroller only runs on 'running'); CampaignsController#resume
  # re-fires for that case.
  def enroll_new_matches
    return unless @campaign.audience_mode == 'dynamic' && @campaign.status == 'running'
    return unless defined?(CampaignAudienceEnrollerJob)

    CampaignAudienceEnrollerJob.perform_later(@campaign.id)
  end

  def set_campaign
    @campaign = @company.campaigns.active.find(params[:campaign_id])
  rescue ActiveRecord::RecordNotFound
    render json: { error: 'Campaign not found' }, status: :not_found
  end

  def editable?
    # 'paused' MUST be editable — the lock error tells users to "Pause it to
    # edit", so a paused campaign has to be unlocked or that instruction is a
    # dead end (the exact bug this fixes).
    %w[draft scheduled paused].include?(@campaign.status)
  end

  def audience_params
    params.require(:campaign_audience).permit(
      :source_type, :location_id, :saved_audience_id,
      :exclude_active_campaign_enrollees, :exclude_active_nurture_enrollees,
      additional_source_types: [],
      filter_tree: {}, exclude_filter_tree: {}
    )
  end

  # Allowlist to the three supported source types; drop the primary from the
  # extras (only meaningful when different). Enroller/JSON layers already
  # tolerate blank/nil, so we just normalize into a clean string array.
  def normalize_additional_source_types(raw)
    allowed = %w[Lead Contact Account]
    Array(raw).map(&:to_s).map(&:strip).select { |t| allowed.include?(t) }.uniq
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
      manual_exclude_ids: audience.try(:manual_exclude_ids),
      exclude_active_campaign_enrollees: audience.exclude_active_campaign_enrollees,
      exclude_active_nurture_enrollees: audience.exclude_active_nurture_enrollees
    ).count
    audience.update!(estimated_count: count, estimated_at: Time.current)
  rescue Audiences::FilterCompiler::CompilationError => e
    # A filter referencing a field invalid for the source type (e.g. a Lead field on a
    # Contact audience) must not 500 the save — persist the audience, blank the estimate.
    Rails.logger.warn "[CampaignAudiences] estimate compile failed: #{e.message}"
    audience.update_columns(estimated_count: 0, estimated_at: Time.current)
  end

  def audience_json(audience)
    {
      id: audience.id,
      campaign_id: audience.campaign_id,
      source_type: audience.source_type,
      additional_source_types: Array(audience.try(:additional_source_types)),
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
