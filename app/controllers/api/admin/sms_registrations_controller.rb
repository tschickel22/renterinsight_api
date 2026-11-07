# frozen_string_literal: true

# Every dealer's own texting registration (E96 phase 4), for the platform
# team: where each is, rejections, and the button that sends one to the
# carriers. Sending costs a vetting fee and starts a monthly campaign fee, so
# it is a person's decision, never automatic. Platform admins only.
class Api::Admin::SmsRegistrationsController < ApplicationController
  before_action :require_platform_admin!
  before_action :set_registration, only: %i[send_to_carriers check]

  def index
    rows = SmsRegistration.includes(:company).where.not(status: 'draft').order(updated_at: :desc).limit(200)
    render json: { items: rows.map { |r| json(r) } }
  end

  def send_to_carriers
    SmsRegistration::Submitter.new(@registration).call
    render json: json(@registration.reload)
  rescue SmsRegistration::Submitter::Error => e
    render json: { error: e.message, registration: json(@registration.reload) }, status: :unprocessable_entity
  end

  def check
    SmsRegistration::StatusPoller.new(@registration).call
    render json: json(@registration.reload)
  end

  private

  def set_registration
    @registration = SmsRegistration.find(params[:id])
  rescue ActiveRecord::RecordNotFound
    render json: { error: 'Not found' }, status: :not_found
  end

  def json(r)
    { id: r.id, company_id: r.company_id, company: r.company&.name, status: r.status, brand_type: r.brand_type,
      legal_name: r.business['legal_name'], dealer_name: r.dealer_name, stages: r.stages, brand_status: r.brand_status,
      campaign_status: r.campaign_status, campaign_id: r.campaign_id, phone_number: r.phone_number,
      rejection_reason: r.rejection_reason, submitted_at: r.submitted_at, sent_to_carriers_at: r.sent_to_carriers_at,
      live_at: r.live_at, events: Array(r.events).last(12), problems: r.problems }
  end
end
