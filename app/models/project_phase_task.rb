# frozen_string_literal: true

class ProjectPhaseTask < ApplicationRecord
  STATUSES = %w[pending completed].freeze

  belongs_to :project_phase
  belongs_to :company
  belongs_to :completed_by, class_name: 'User', optional: true
  belongs_to :assigned_to, class_name: 'User', optional: true

  # assigned_to_id comes from the client; it must be one of this company's users.
  validate :assigned_to_in_company, if: -> { assigned_to_id.present? && will_save_change_to_assigned_to_id? }

  # Polymorphic contractor assignments (Phase 2B)
  has_many :contractor_assignments, as: :assignable, dependent: :destroy

  validates :name, presence: true
  validates :status, inclusion: { in: STATUSES }

  scope :ordered,           -> { order(:position) }
  scope :pending,           -> { where(status: 'pending') }
  scope :completed,         -> { where(status: 'completed') }
  scope :client_visible,    -> { where(visible_to_client: true) }
  scope :client_actionable, -> { where(client_actionable: true) }

  def complete!(by: nil)
    update!(status: 'completed', completed_at: Time.current, completed_by: by)
  end

  def reopen!
    update!(status: 'pending', completed_at: nil, completed_by: nil)
  end

  def acknowledged?
    client_acknowledged_at.present?
  end

  def work_log_count
    AssignmentWorkLog.where(contractor_assignment_id: contractor_assignments.select(:id)).count
  end

  private

  def assigned_to_in_company
    return if User.where(id: assigned_to_id, company_id: company_id).exists?

    errors.add(:assigned_to_id, 'is not a user in this company')
  end
end
