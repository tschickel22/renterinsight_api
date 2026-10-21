# frozen_string_literal: true

class TwilioAccount < ApplicationRecord
  belongs_to :company
  belongs_to :location, optional: true

  encrypts :auth_token

  # sub_account_sid and auth_token are legacy for numbers on our master account;
  # a dealer's own account keeps its credentials there (own_account?).
  validates :phone_number, presence: true, uniqueness: true,
            format: { with: /\A\+\d{7,15}\z/, message: "must be in E.164 format (e.g., +15551234567)" }
  validates :phone_number_sid, presence: true
  validates :status, presence: true, inclusion: { in: %w[provisioning active suspended failed] }

  scope :active, -> { where(status: 'active') }
  scope :provisioning, -> { where(status: 'provisioning') }

  # Resolve the active TwilioAccount for a given company (optionally location-specific).
  # Prefers an active number assigned to the location; falls back to a company-wide
  # number (location_id IS NULL); else nil. NEVER returns master/platform.
  def self.resolve_for(company_id:, location_id: nil)
    if location_id.present?
      loc = where(company_id: company_id, location_id: location_id, status: 'active').first
      return loc if loc
    end
    where(company_id: company_id, location_id: nil, status: 'active').first
  end

  def active? = status == 'active'
  def suspended? = status == 'suspended'
  def failed? = status == 'failed'
  def provisioning? = status == 'provisioning'

  # A dealer's own Twilio number, on their own account (metadata own_account).
  # It works like a number we provisioned, two-way texting included, but it is
  # sent with their account SID and token (sub_account_sid / auth_token) and
  # never through our Messaging Service: Twilio answers 404 for another
  # account's service.
  def own_account? = metadata.to_h['own_account'] == true

  def api_credentials
    own_account? ? [sub_account_sid, auth_token] : TwilioSmsService.master_credentials
  end

  def messaging_service_sid
    own_account? ? metadata.to_h['messaging_service_sid'].presence : TwilioSmsService.master_messaging_service_sid
  end

  # Sends from this number, with the account and service it belongs to.
  def send_sms(to:, body:)
    sid, token = api_credentials
    TwilioSmsService.send(to: to, body: body, from_number: phone_number,
                          account_sid: sid, auth_token: token, messaging_service_sid: messaging_service_sid)
  end

  def mark_active!
    update!(status: 'active', provisioned_at: Time.current)
  end

  def mark_failed!(error_message = nil)
    meta = metadata || {}
    meta['last_error'] = error_message
    meta['failed_at'] = Time.current.iso8601
    update!(status: 'failed', metadata: meta)
  end

  def mark_suspended!
    update!(status: 'suspended')
  end
end
