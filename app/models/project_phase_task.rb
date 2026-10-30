# frozen_string_literal: true

class ProjectPhaseTask < ApplicationRecord
  STATUSES = %w[pending completed].freeze

  belongs_to :project_phase
  belongs_to :company
  belongs_to :completed_by, class_name: 'User', optional: true
  belongs_to :assigned_to, class_name: 'User', optional: true
  # On an installer's copy of a linked job: the dealer's task it came from (E68).
  belongs_to :linked_task, class_name: 'ProjectPhaseTask', optional: true

  # assigned_to_id comes from the client; it must be one of this company's users.
  validate :assigned_to_in_company, if: -> { assigned_to_id.present? && will_save_change_to_assigned_to_id? }

  # Polymorphic contractor assignments (Phase 2B)
  has_many :contractor_assignments, as: :assignable, dependent: :destroy

  validates :name, presence: true
  validates :status, inclusion: { in: STATUSES }

  after_commit :sync_linked_task, on: :update,
               if: -> { linked_task_id.present? && saved_change_to_status? && !Current.project_link_sync }
  # The last open step of a closed phase is ticked: its Review Updates item
  # (Project#note_open_tasks) is done.
  after_commit :clear_open_tasks_item, on: :update, if: -> { saved_change_to_status? && status == 'completed' }

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

  def sync_linked_task
    ProjectLinkTaskSyncJob.perform_later(id)
  end

  def clear_open_tasks_item
    phase = project_phase
    return unless phase&.status == 'completed' && !phase.project_phase_tasks.pending.exists?

    ProjectNotices.close!(subject: phase, kinds: 'phase_open_tasks', resolution: 'steps done', by: completed_by)
  end

  def assigned_to_in_company
    return if User.where(id: assigned_to_id, company_id: company_id).exists?

    errors.add(:assigned_to_id, 'is not a user in this company')
  end
end
