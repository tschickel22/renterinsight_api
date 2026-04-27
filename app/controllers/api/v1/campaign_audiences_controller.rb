class Api::V1::CampaignAudiencesController < ApplicationController
  before_action :set_company_scope
  before_action :set_campaign

  def preview
    return unless authorize_action!('campaigns', 'read')

    source_type = params[:source_type] || @campaign.campaign_audience&.source_type
    base = case source_type
           when 'Lead'    then @company.leads
           when 'Contact' then @company.contacts.where(is_deleted: [false, nil])
           when 'Account' then @company.accounts.where(is_deleted: [false, nil])
           else
             return render(json: { error: 'Invalid source_type' }, status: :unprocessable_entity)
           end

    sample = base.limit(20).map do |r|
      { id: r.id, name: record_display_name(r), email: record_email(r) }
    end
    render json: {
      count: base.count,
      sample: sample,
      filter_evaluation: 'phase_b_pending',
      channel: @campaign.channel,
      sms_opt_in_filter_active: @campaign.sms_channel? && !@campaign.campaign_audience&.sms_compliance_override?,
      sms_compliance_override: @campaign.campaign_audience&.sms_compliance_override? || false
    }
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

    render json: { success: true, acknowledged_at: meta['compliance_override_at'] }
  end

  def recompute
    return unless authorize_action!('campaigns', 'update')
    audience = @campaign.campaign_audience
    return render(json: { error: 'No audience set' }, status: :unprocessable_entity) unless audience

    base = case audience.source_type
           when 'Lead'    then @company.leads
           when 'Contact' then @company.contacts.where(is_deleted: [false, nil])
           when 'Account' then @company.accounts.where(is_deleted: [false, nil])
           end
    audience.update!(estimated_count: base.count, estimated_at: Time.current)
    render json: { count: audience.estimated_count, estimated_at: audience.estimated_at }
  end

  private

  def set_campaign
    @campaign = @company.campaigns.active.find(params[:campaign_id])
  rescue ActiveRecord::RecordNotFound
    render json: { error: 'Campaign not found' }, status: :not_found
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
