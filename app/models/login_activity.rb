# frozen_string_literal: true

class LoginActivity < ApplicationRecord
  # Polymorphic association - can belong to User or BuyerPortalAccess
  belongs_to :user, polymorphic: true, optional: true

  validates :logged_in_at, presence: true
  
  scope :recent, -> { order(logged_in_at: :desc) }
  scope :for_user, ->(user_id, user_type = 'User') { where(user_id: user_id, user_type: user_type) }

  # Keep only the last N sessions for a user
  def self.keep_last_n_for_user(user_id, user_type = 'User', limit = 3)
    activities = for_user(user_id, user_type).recent.to_a
    
    if activities.size > limit
      # Delete all but the most recent N
      to_delete = activities[limit..-1]
      where(id: to_delete.map(&:id)).delete_all
    end
  end

  # Record a new login and clean up old ones
  def self.record_login(user_id:, user_type: 'User', ip_address: nil, user_agent: nil)
    create!(
      user_id: user_id,
      user_type: user_type,
      ip_address: ip_address,
      user_agent: user_agent,
      logged_in_at: Time.current
    )
    
    # Keep only last 3 sessions
    keep_last_n_for_user(user_id, user_type, 3)
  end
end
