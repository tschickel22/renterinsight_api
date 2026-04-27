class Api::V1::CampaignEventsController < ApplicationController
  before_action :set_company_scope
  before_action :set_campaign

  def index
    return unless authorize_action!('campaigns', 'read')

    events = @campaign.campaign_events
    events = events.where(event_type: params[:event_type]) if params[:event_type].present?

    page = (params[:page] || 1).to_i
    per_page = [(params[:per_page] || 100).to_i, 500].min
    total = events.count
    events = events.order(occurred_at: :desc).offset((page - 1) * per_page).limit(per_page)

    render json: {
      items: events.map { |e| { id: e.id, event_type: e.event_type, occurred_at: e.occurred_at, payload: e.payload, campaign_enrollment_id: e.campaign_enrollment_id } },
      meta: { total: total, page: page, per_page: per_page, total_pages: (total.to_f / per_page).ceil }
    }
  end

  private

  def set_campaign
    @campaign = @company.campaigns.active.find(params[:campaign_id])
  rescue ActiveRecord::RecordNotFound
    render json: { error: 'Campaign not found' }, status: :not_found
  end
end
