# frozen_string_literal: true

# A tokenized, customer-safe snapshot of one or more Deal Desk scenarios that a
# rep sent to a buyer via SMS/email. The `snapshot` JSONB is authoritative for
# the public view — the underlying scenarios can be edited afterward without
# changing what the customer sees.
class DealDeskShare < ApplicationRecord
  belongs_to :company
  belongs_to :deal
  belongs_to :shared_by, class_name: 'User', optional: true

  validates :public_token, presence: true, uniqueness: true
  validate  :scenario_ids_present
  validate  :at_least_one_channel

  before_validation :generate_public_token, on: :create
  before_validation :default_expires_at,    on: :create

  scope :active, -> { where('expires_at IS NULL OR expires_at > ?', Time.current) }

  def expired?
    expires_at.present? && expires_at <= Time.current
  end

  def register_view!
    now = Time.current
    updates = { view_count: view_count + 1, last_viewed_at: now }
    updates[:first_viewed_at] = now if first_viewed_at.blank?
    update_columns(updates)
  end

  # Public URL — frontend hosts the customer-facing package at /q/desk/<token>.
  # Matches the /q/<token> pattern used by agreements/quotes elsewhere in the app.
  def public_url(base_url)
    "#{base_url}/q/desk/#{public_token}"
  end

  private

  def generate_public_token
    return if public_token.present?
    loop do
      # 12 bytes → ~16 chars base64: short enough to fit comfortably in an SMS,
      # long enough to be unguessable in practice (~10^18 keyspace).
      self.public_token = SecureRandom.urlsafe_base64(12)
      break unless DealDeskShare.exists?(public_token: public_token)
    end
  end

  def default_expires_at
    self.expires_at ||= 30.days.from_now
  end

  def scenario_ids_present
    if scenario_ids.blank? || !scenario_ids.is_a?(Array) || scenario_ids.empty?
      errors.add(:scenario_ids, 'must include at least one scenario')
    end
  end

  def at_least_one_channel
    if channels.blank? || (channels & %w[email sms]).empty?
      errors.add(:channels, 'must include email or sms')
    end
  end
end
