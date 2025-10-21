class ApprovalWorkflow < ApplicationRecord
  belongs_to :deal
  belongs_to :requested_by, class_name: 'User', optional: true
  belongs_to :approved_by, class_name: 'User', optional: true
  
  has_many :approval_steps, dependent: :destroy
  
  validates :workflow_type, presence: true
  validates :status, presence: true, inclusion: { in: %w[pending approved rejected cancelled] }
  
  scope :pending, -> { where(status: 'pending') }
  scope :approved, -> { where(status: 'approved') }
  scope :rejected, -> { where(status: 'rejected') }
  scope :by_type, ->(type) { where(workflow_type: type) }
  
  def complete?
    %w[approved rejected cancelled].include?(status)
  end
  
  def all_steps_approved?
    approval_steps.all? { |step| step.status == 'approved' }
  end
  
  def any_step_rejected?
    approval_steps.any? { |step| step.status == 'rejected' }
  end
end
