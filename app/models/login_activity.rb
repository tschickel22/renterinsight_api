# frozen_string_literal: true

class LoginActivity < ApplicationRecord
  belongs_to :user, polymorphic: true

  validates :logged_in_at, presence: true

  # Scopes
  scope :recent, -> { order(logged_in_at: :desc) }
  scope :for_user, ->(user_id) { where(user_id: user_id) }

  # Record a login activity
  def self.record_login(user_id:, user_type:, ip_address: nil, user_agent: nil)
    create!(
      user_id: user_id,
      user_type: user_type,
      ip_address: ip_address,
      user_agent: user_agent,
      logged_in_at: Time.current
    )
  end
end
