# frozen_string_literal: true

class WebhookDelivery < ApplicationRecord
  # Associations
  belongs_to :webhook_endpoint

  # Validations
  validates :event, presence: true
  validates :payload, presence: true

  # Scopes
  scope :successful, -> { where(response_code: 200..299) }
  scope :failed, -> { where.not(response_code: 200..299).or(where(response_code: nil)) }
  scope :pending, -> { where(delivered_at: nil) }
  scope :recent, -> { order(created_at: :desc) }

  # Instance methods
  def successful?
    response_code.present? && response_code.between?(200, 299)
  end

  def failed?
    !successful?
  end

  def delivered?
    delivered_at.present?
  end

  def record_response!(code:, body:)
    update!(
      response_code: code,
      response_body: body.to_s.truncate(10_000),
      delivered_at: Time.current,
      attempts: attempts + 1
    )
  end

  def max_attempts_reached?
    attempts >= 5
  end
end
