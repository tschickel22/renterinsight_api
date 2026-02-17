# frozen_string_literal: true

class WebhookEndpoint < ApplicationRecord
  # Associations
  belongs_to :company
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

  # Callbacks
  before_validation :generate_secret, on: :create

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
    update!(status: "inactive")
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
