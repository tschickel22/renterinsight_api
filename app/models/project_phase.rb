# frozen_string_literal: true

class ProjectPhase < ApplicationRecord
  STATUSES = %w[not_started in_progress completed skipped].freeze

  belongs_to :project
  belongs_to :company
  belongs_to :completed_by, class_name: 'User', foreign_key: 'completed_by_id', optional: true
  # Whole-phase owners (E69); tasks inherit them. See ProjectAssignmentService.
  belongs_to :assigned_vendor, class_name: 'Vendor', optional: true
  belongs_to :assigned_to, class_name: 'User', optional: true
  has_many :project_phase_tasks, -> { order(:position) }, dependent: :destroy
  has_many :tasks, class_name: 'ProjectTask', dependent: :destroy
  has_many :project_cost_items, dependent: :destroy
  has_many :project_material_usages, dependent: :destroy
  has_many :project_documents, as: :documentable, dependent: :destroy

  # Validations
  validates :name, presence: true
  validates :position, presence: true, numericality: { greater_than_or_equal_to: 0 }
  validates :status, presence: true, inclusion: { in: STATUSES }
  validate :not_held_for_price, on: :update

  # Scopes
  scope :ordered, -> { order(:position) }
  scope :client_visible, -> { where(visible_to_client: true) }
  scope :pending, -> { where(status: %w[not_started in_progress]) }
  scope :done, -> { where(status: %w[completed skipped]) }
  scope :active_phase, -> { where(status: 'in_progress') }

  # ============================================================================
  # STATE TRANSITIONS
  # ============================================================================

  def mark_in_progress!
    return if status == 'in_progress'
    update!(
      status: 'in_progress',
      started_at: Time.current
    )
    send_start_notification! if notify_client_on_start && !client_notified_start
  end

  def mark_complete!(completed_by: nil)
    return if status == 'completed'
    update!(
      status: 'completed',
      completed_at: Time.current,
      completed_by_id: completed_by&.id
    )
    send_completion_notification! if notify_client_on_complete && !client_notified_complete
  end

  # ============================================================================
  # DISPLAY HELPERS
  # ============================================================================

  def duration_days
    return nil unless started_at && completed_at
    ((completed_at - started_at) / 1.day).round
  end

  # ============================================================================
  # ROLL-UP FROM TASKS (task-level dates roll up to phase)
  # ============================================================================

  # Sum of task estimated_days, falls back to phase's own estimated_days
  def computed_estimated_days
    tasks = project_phase_tasks
    if tasks.any? && tasks.where.not(estimated_days: nil).exists?
      tasks.sum(:estimated_days)
    else
      estimated_days
    end
  end

  # Earliest task start date, falls back to phase's own
  def computed_start_date
    tasks = project_phase_tasks
    if tasks.any? && tasks.where.not(estimated_start_date: nil).exists?
      tasks.minimum(:estimated_start_date)
    else
      estimated_start_date
    end
  end

  # Latest task completion date, falls back to phase's own
  def computed_completion_date
    tasks = project_phase_tasks
    if tasks.any? && tasks.where.not(estimated_completion_date: nil).exists?
      tasks.maximum(:estimated_completion_date)
    else
      estimated_completion_date
    end
  end

  # Calculate % complete based on tasks (if any), otherwise 0 or 100
  def task_progress_percent
    tasks = project_phase_tasks
    return nil if tasks.empty?  # nil means no tasks defined
    total = tasks.count
    done  = tasks.where(status: 'completed').count
    total > 0 ? ((done.to_f / total) * 100).round : 0
  end

  def tasks_summary
    tasks = project_phase_tasks
    return nil if tasks.empty?
    { total: tasks.count, completed: tasks.where(status: 'completed').count }
  end

  def overdue?
    due = computed_completion_date
    return false unless due
    return false if status.in?(%w[completed skipped])
    due < Date.current
  end

  def days_until_estimated_completion
    due = computed_completion_date
    return nil unless due
    (due - Date.current).to_i
  end

  def status_display
    case status
    when 'not_started' then 'Not Started'
    when 'in_progress' then 'In Progress'
    when 'completed' then 'Completed'
    when 'skipped' then 'Skipped'
    else status&.titleize
    end
  end

  def recalculate_costs!
    # Incurred only; pending (committed) lines are reported apart.
    update_column(:actual_cost, project_cost_items.not_deleted.where.not(status: 'pending').sum(:amount))
  end

  after_save :notify_status_change, if: :saved_change_to_status?
  # A phase handed to or from a linked installer company follows the other
  # side (E68 step 5d). The job decides which fields cross in which direction.
  after_commit :sync_linked_phase, on: :update, if: :linked_sync_change?

  SYNCED_FIELDS = %w[status started_at completed_at estimated_start_date estimated_completion_date].freeze

  # The installer company running this dealer phase, while the hand-off is
  # live. Its status comes from them.
  def linked_installer_name
    link = ProjectLinkPhase.joins(:project_link).where(dealer_phase_id: id, project_links: { status: 'accepted' }).first&.project_link
    link&.installer_company&.name
  end

  # On the installer's side of a priced job (E68 step 6): why this phase
  # can't start yet, while a price or change order waits for the dealer.
  def price_hold_message
    map = ProjectLinkPhase.includes(project_link: :dealer_company).find_by(installer_phase_id: id)
    pl = map&.project_link
    return nil unless pl&.accepted? && !pl.legacy_price?

    dealer = pl.dealer_company.name
    if (held = pl.hold_for(map.dealer_phase_id))
      "#{name} can't start until #{dealer} approves #{held.price? ? 'the price' : held.label.downcase}."
    elsif !pl.price_agreed?
      "#{name} can't start until #{dealer} approves a price for the job."
    end
  end

  # Would this save start a phase that isn't started yet?
  def starting?
    status_was == 'not_started' && status.in?(%w[in_progress completed])
  end

  private

  def not_held_for_price
    return unless will_save_change_to_status? && starting?

    msg = price_hold_message
    errors.add(:base, msg) if msg
  end

  def linked_sync_change?
    return false if Current.project_link_sync

    (saved_changes.keys & SYNCED_FIELDS).any? &&
      ProjectLinkPhase.where(dealer_phase_id: id).or(ProjectLinkPhase.where(installer_phase_id: id)).exists?
  end

  def sync_linked_phase
    ProjectLinkSyncJob.perform_later(id)
  end

  def notify_status_change
    ProjectNotificationService.notify_phase_change(self, status_before_last_save, status)
  end

  def send_start_notification!
    update_column(:client_notified_start, true)
    Rails.logger.info "[ProjectPhase] Phase '#{name}' started for project #{project_id} — notification queued"
  end

  def send_completion_notification!
    update_column(:client_notified_complete, true)
    Rails.logger.info "[ProjectPhase] Phase '#{name}' completed for project #{project_id} — notification queued"
  end
end
