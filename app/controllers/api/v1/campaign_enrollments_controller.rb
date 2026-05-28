class Api::V1::CampaignEnrollmentsController < ApplicationController
  before_action :set_company_scope
  before_action :set_campaign
  before_action :set_enrollment, only: %i[show unenroll]

  def index
    return unless authorize_action!('campaigns', 'read')

    enrollments = @campaign.campaign_enrollments.real
    enrollments = enrollments.where(status: params[:status]) if params[:status].present?

    page = (params[:page] || 1).to_i
    per_page = [(params[:per_page] || 50).to_i, 200].min
    total = enrollments.count
    enrollments = enrollments.order(created_at: :desc).offset((page - 1) * per_page).limit(per_page)

    render json: {
      items: enrollments.map { |e| enrollment_json(e) },
      meta: { total: total, page: page, per_page: per_page, total_pages: (total.to_f / per_page).ceil }
    }
  end

  def show
    return unless authorize_action!('campaigns', 'read')
    render json: enrollment_json(@enrollment, with_timeline: true)
  end

  def unenroll
    return unless authorize_action!('campaigns', 'update')
    @enrollment.update!(status: 'paused')
    CampaignEvent.create!(
      company_id: @company.id, campaign_id: @campaign.id,
      campaign_enrollment_id: @enrollment.id,
      event_type: 'unenrolled', occurred_at: Time.current,
      payload: { reason: 'manual_unenroll', user_id: current_user.id }
    )
    render json: enrollment_json(@enrollment)
  end

  private

  def set_campaign
    @campaign = @company.campaigns.active.find(params[:campaign_id])
  rescue ActiveRecord::RecordNotFound
    render json: { error: 'Campaign not found' }, status: :not_found
  end

  def set_enrollment
    @enrollment = @campaign.campaign_enrollments.find(params[:id])
  rescue ActiveRecord::RecordNotFound
    render json: { error: 'Enrollment not found' }, status: :not_found
  end

  def enrollment_json(e, with_timeline: false)
    base = {
      id: e.id,
      recipient_type: e.recipient_type,
      recipient_id: e.recipient_id,
      recipient_name: recipient_name_for(e.recipient_type, e.recipient_id),
      email_address_snapshot: e.email_address_snapshot,
      status: e.status,
      current_step_index: e.current_step_index,
      next_send_at: e.next_send_at,
      last_sent_at: e.last_sent_at,
      goal_met_at: e.goal_met_at,
      goal_met_reason: e.goal_met_reason,
      unsubscribed_at: e.unsubscribed_at,
      bounced_at: e.bounced_at,
      failure_reason: e.failure_reason,
      created_at: e.created_at
    }
    return base unless with_timeline
    base.merge(
      sends: e.campaign_sends.order(:created_at).map { |s| { id: s.id, sent_at: s.sent_at, opened_at: s.opened_at, clicked_at: s.clicked_at, replied_at: s.replied_at } },
      events: e.campaign_events.order(:occurred_at).map { |ev| { event_type: ev.event_type, occurred_at: ev.occurred_at, payload: ev.payload } }
    )
  end

  def recipient_name_for(recipient_type, recipient_id)
    fallback = "#{recipient_type} ##{recipient_id}"
    klass = case recipient_type
            when 'Lead'    then Lead
            when 'Contact' then Contact
            when 'User'    then User
            end
    return fallback unless klass

    record = klass.find_by(id: recipient_id)
    return fallback unless record

    name = [record.first_name, record.last_name].compact.map(&:to_s).map(&:strip).reject(&:empty?).join(' ')
    name.presence || fallback
  rescue => e
    Rails.logger.warn "[CampaignEnrollmentsController] recipient_name_for(#{recipient_type}, #{recipient_id}): #{e.message}"
    "#{recipient_type} ##{recipient_id}"
  end
end
