# frozen_string_literal: true

class ContractorAssignment < ApplicationRecord
  REVIEW_STATUS_PENDING = 'pending_review'
  REVIEW_STATUS_APPROVED = 'approved'
  REVIEW_STATUS_REVISION_REQUESTED = 'revision_requested'
  REVIEW_STATUS_REJECTED = 'rejected'

  REVIEWABLE_STATUSES = [REVIEW_STATUS_PENDING, REVIEW_STATUS_APPROVED, REVIEW_STATUS_REVISION_REQUESTED, REVIEW_STATUS_REJECTED].freeze

  belongs_to :contractor
  belongs_to :assignable, polymorphic: true
  belongs_to :company
  belongs_to :assigned_by, class_name: 'User', optional: true
  belongs_to :reviewed_by, class_name: 'User', optional: true

  has_many :work_logs, class_name: 'AssignmentWorkLog', dependent: :destroy

  validates :status, inclusion: { in: %w[assigned accepted in_progress completed declined] }

  after_commit :notify_on_assignment, on: :create
  after_commit :notify_on_review_changes, on: :update

  def submit_for_review!(summary: nil, photos: [])
    unless status.in?(%w[in_progress completed]) || review_status == REVIEW_STATUS_REVISION_REQUESTED
      raise StandardError, "Cannot submit for review from current status: #{status} / review: #{review_status}"
    end

    update!(
      review_status: REVIEW_STATUS_PENDING,
      submitted_for_review_at: Time.current,
      completion_summary: summary.presence || completion_summary,
      completion_photos: photos.present? ? photos : completion_photos,
      status: 'completed',
      completed_at: completed_at || Time.current,
      revision_count: review_status == REVIEW_STATUS_REVISION_REQUESTED ? (revision_count || 0) + 1 : (revision_count || 0)
    )
  end

  def approve_review!(reviewer:, notes: nil)
    raise StandardError, "Can only approve pending reviews" unless review_status == REVIEW_STATUS_PENDING

    update!(
      review_status: REVIEW_STATUS_APPROVED,
      reviewed_by: reviewer,
      reviewed_at: Time.current,
      review_notes: notes
    )

    if assignable_type == 'ProjectPhaseTask'
      sync_phase_task_completed!
      check_phase_completion!
    end
  end

  def request_revision!(reviewer:, notes:)
    raise StandardError, "Can only request revision on pending reviews" unless review_status == REVIEW_STATUS_PENDING
    raise StandardError, "Revision notes are required" if notes.blank?

    update!(
      review_status: REVIEW_STATUS_REVISION_REQUESTED,
      reviewed_by: reviewer,
      reviewed_at: Time.current,
      revision_notes: notes,
      status: 'in_progress'
    )
  end

  def reject_review!(reviewer:, notes: nil)
    raise StandardError, "Can only reject pending reviews" unless review_status == REVIEW_STATUS_PENDING

    update!(
      review_status: REVIEW_STATUS_REJECTED,
      reviewed_by: reviewer,
      reviewed_at: Time.current,
      review_notes: notes
    )
  end

  def pending_review?
    review_status == REVIEW_STATUS_PENDING
  end

  def review_submitted?
    review_status.present?
  end

  private

  def sync_phase_task_completed!
    return unless assignable.present?
    assignable.update(status: 'completed', completed_at: Time.current) unless assignable.status == 'completed'
  end

  # If all tasks in the phase are completed, mark the phase completed.
  # The ProjectPhase after_save callback will fire ProjectNotificationService.notify_phase_change
  # which handles client notifications via notification_preferences.
  def check_phase_completion!
    return unless assignable.present?

    phase = assignable.project_phase rescue nil
    return unless phase.present?

    project = phase.project rescue nil
    return unless project.present?

    total_tasks = phase.project_phase_tasks.count
    completed_tasks = phase.project_phase_tasks.where(status: 'completed').count

    return unless total_tasks > 0 && completed_tasks == total_tasks

    phase.update(status: 'completed') unless phase.status == 'completed'

    total_phases = project.project_phases.count
    completed_phases = project.project_phases.where(status: 'completed').count
    progress = total_phases > 0 ? ((completed_phases.to_f / total_phases) * 100).round : 0
    project.update(progress_percent: progress)
  rescue => e
    Rails.logger.error("[ContractorAssignment] Error checking phase completion: #{e.message}")
  end

  # Email to contractor is batched via ContractorAssignmentNotifierJob with a
  # 10-minute debounce. If another assignment for the same contractor is already
  # waiting to be notified, we skip enqueueing (the pending job will pick this up).
  # This avoids accidental-assignment spam and consolidates multiple assignments
  # into one email.
  def notify_on_assignment
    return unless status == 'assigned'

    # Debounce: if there's already a pending unnotified assignment for this
    # contractor, a job is already queued to batch them. Don't enqueue another.
    already_pending = ContractorAssignment.where(
      contractor_id: contractor_id,
      notified_at: nil,
      notification_paused_at: nil,
      notification_skipped_at: nil
    ).where.not(id: id).exists?

    return if already_pending

    delay = (ENV['CONTRACTOR_NOTIFICATION_DELAY_MINUTES'] || 10).to_i.minutes
    ContractorAssignmentNotifierJob.set(wait: delay).perform_later(contractor_id)
  rescue => e
    Rails.logger.error("[ContractorAssignment] Notification error on create: #{e.message}")
  end

  # Bell notifications + ActionCable toasts fire immediately for real-time
  # visibility. Email is batched per-project so multiple submissions on one
  # project become a single email.
  def notify_on_review_changes
    return unless saved_change_to_review_status?

    case review_status
    when REVIEW_STATUS_PENDING
      # Immediate: bell + ActionCable toast for dealers
      ProjectNotificationService.announce_review_submitted(self)
      # Batched email:
      project_id = resolve_project_id
      if project_id
        already_pending = ContractorAssignment.joins(
          "INNER JOIN project_phase_tasks ON project_phase_tasks.id = contractor_assignments.assignable_id"
        ).joins(
          "INNER JOIN project_phases ON project_phases.id = project_phase_tasks.project_phase_id"
        ).where(
          contractor_assignments: { assignable_type: 'ProjectPhaseTask', review_status: 'pending_review', review_notified_at: nil },
          project_phases: { project_id: project_id }
        ).where.not(id: id).exists?

        unless already_pending
          delay = (ENV['DEALER_REVIEW_NOTIFICATION_DELAY_MINUTES'] || 10).to_i.minutes
          DealerReviewNotifierJob.set(wait: delay).perform_later(project_id)
        end
      end
    when REVIEW_STATUS_APPROVED
      ProjectNotificationService.notify_review_approved(self, reviewed_by) if reviewed_by.present?
    when REVIEW_STATUS_REVISION_REQUESTED
      ProjectNotificationService.notify_revision_requested(self, reviewed_by) if reviewed_by.present?
    when REVIEW_STATUS_REJECTED
      ProjectNotificationService.notify_review_rejected(self, reviewed_by) if reviewed_by.present?
    end
  rescue => e
    Rails.logger.error("[ContractorAssignment] Notification error on review change: #{e.message}")
  end

  def resolve_project_id
    return nil unless assignable_type == 'ProjectPhaseTask'
    assignable&.project_phase&.project_id
  rescue
    nil
  end
end
