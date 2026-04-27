class Api::V1::CampaignAudiencesController < ApplicationController
  before_action :set_company_scope
  before_action :set_campaign

  def preview
    return unless authorize_action!('campaigns', 'read')

    source_type = params[:source_type] || @campaign.campaign_audience&.source_type
    base = case source_type
           when 'Lead'    then @company.leads.where(is_deleted: [false, nil])
           when 'Contact' then @company.contacts.where(is_deleted: [false, nil])
           when 'Account' then @company.accounts.where(is_deleted: [false, nil])
           else
             return render(json: { error: 'Invalid source_type' }, status: :unprocessable_entity)
           end

    sample = base.limit(20).map do |r|
      { id: r.id, name: record_display_name(r), email: record_email(r) }
    end
    render json: { count: base.count, sample: sample, filter_evaluation: 'phase_b_pending' }
  end

  def recompute
    return unless authorize_action!('campaigns', 'update')
    audience = @campaign.campaign_audience
    return render(json: { error: 'No audience set' }, status: :unprocessable_entity) unless audience

    base = case audience.source_type
           when 'Lead'    then @company.leads.where(is_deleted: [false, nil])
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
