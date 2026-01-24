# frozen_string_literal: true

class LoginActivity < ApplicationRecord
  belongs_to :user, polymorphic: true

  validates :logged_in_at, presence: true

  # Scopes
  scope :recent, -> { order(logged_in_at: :desc) }
  scope :for_user, ->(user_id, user_type = nil) { 
    query = where(user_id: user_id)
    query = query.where(user_type: user_type) if user_type.present?
    query
  }

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
