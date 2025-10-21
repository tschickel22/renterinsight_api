class ApprovalStep < ApplicationRecord
  belongs_to :approval_workflow
  belongs_to :approver_user, class_name: 'User', optional: true
  
  has_many :approval_actions, dependent: :destroy
  
  validates :step_order, presence: true
  validates :status, presence: true, inclusion: { in: %w[pending approved rejected cancelled] }
  
  scope :pending, -> { where(status: 'pending') }
  scope :completed, -> { where(status: %w[approved rejected]) }
  scope :by_order, -> { order(step_order: :asc) }
  
  def complete?
    %w[approved rejected cancelled].include?(status)
  end
  
  def approved?
    status == 'approved'
  end
  
  def rejected?
    status == 'rejected'
  end
end
