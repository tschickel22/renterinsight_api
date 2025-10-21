class ApprovalAction < ApplicationRecord
  belongs_to :approval_step
  belongs_to :user
  
  validates :action_type, presence: true, inclusion: { in: %w[approved rejected cancelled requested] }
  
  scope :by_type, ->(type) { where(action_type: type) }
  scope :recent, -> { order(actioned_at: :desc) }
  scope :by_user, ->(user_id) { where(user_id: user_id) }
end
