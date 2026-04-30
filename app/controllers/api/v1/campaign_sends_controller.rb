class Api::V1::CampaignSendsController < ApplicationController
  before_action :set_company_scope
  before_action :set_campaign

  def index
    return unless authorize_action!('campaigns', 'read')

    sends = @campaign.campaign_sends
    page = (params[:page] || 1).to_i
    per_page = [(params[:per_page] || 100).to_i, 500].min
    total = sends.count
    sends = sends.order(created_at: :desc).offset((page - 1) * per_page).limit(per_page)

    render json: {
      items: sends.map { |s| send_json(s) },
      meta: { total: total, page: page, per_page: per_page, total_pages: (total.to_f / per_page).ceil }
    }
  end

  def show
    return unless authorize_action!('campaigns', 'read')
    s = @campaign.campaign_sends.find(params[:id])
    render json: send_json(s, full: true)
  rescue ActiveRecord::RecordNotFound
    render json: { error: 'Send not found' }, status: :not_found
  end

  private

  def set_campaign
    @campaign = @company.campaigns.active.find(params[:campaign_id])
  rescue ActiveRecord::RecordNotFound
    render json: { error: 'Campaign not found' }, status: :not_found
  end

  def send_json(s, full: false)
    base = {
      id: s.id, campaign_step_id: s.campaign_step_id,
      campaign_enrollment_id: s.campaign_enrollment_id,
      communication_id: s.communication_id,
      sent_at: s.sent_at, delivered_at: s.delivered_at,
      opened_at: s.opened_at, open_count: s.open_count,
      clicked_at: s.clicked_at, click_count: s.click_count,
      replied_at: s.replied_at, bounced_at: s.bounced_at, bounce_type: s.bounce_type,
      goal_met_at: s.goal_met_at
    }
    return base unless full
    base.merge(inventory_vehicle_ids: s.inventory_vehicle_ids, metadata: s.metadata)
  end
end
