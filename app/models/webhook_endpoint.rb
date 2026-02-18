# frozen_string_literal: true

class WebhookEndpoint < ApplicationRecord
  # Associations
  belongs_to :company, optional: true  # NULL = platform-level webhook
  belongs_to :created_by_user, class_name: "User", foreign_key: "created_by_user_id", optional: true
  has_many :webhook_deliveries, dependent: :destroy

  # Validations
  validates :url, presence: true, format: { with: /\Ahttps:\/\/.+/i, message: "must be an HTTPS URL" }
  validates :events, presence: true
  validates :secret, presence: true
  validates :status, presence: true, inclusion: { in: %w[active inactive] }

  # Scopes
  scope :active, -> { where(status: "active") }
  scope :inactive, -> { where(status: "inactive") }
  scope :for_event, ->(event) { active.where("events @> ?", [event].to_json) }
  scope :platform_level, -> { where(company_id: nil) }
  scope :company_scoped, -> { where.not(company_id: nil) }

  # Callbacks
  before_validation :generate_secret, on: :create

  # Scope helpers
  def platform_level?
    company_id.nil?
  end

  def company_scoped?
    company_id.present?
  end

  # Check if this endpoint should fire for a given location
  def matches_location?(location_id)
    # No location filter = matches all locations
    return true if location_ids.blank?

    # If event has no location context, still deliver
    return true if location_id.nil?

    # Check if the event's location is in our filter list
    location_ids.include?(location_id.to_i)
  end

  # Instance methods
  def active?
    status == "active"
  end

  def inactive?
    status == "inactive"
  end

  def deactivate!
    update!(status: "inactive")
  end

  def activate!
    update!(status: "active", failure_count: 0)
  end

  def record_failure!
    increment!(:failure_count)
    deactivate! if failure_count >= 10
  end

  def record_success!
    update!(failure_count: 0, last_triggered_at: Time.current)
  end

  def sign_payload(payload)
    OpenSSL::HMAC.hexdigest("SHA256", secret, payload.to_json)
  end

  def subscribed_to?(event)
    events.include?(event.to_s)
  end

  private

  def generate_secret
    self.secret = "whsec_#{SecureRandom.hex(32)}" if secret.blank?
  end
end
