# frozen_string_literal: true

class ContractorAssignment < ApplicationRecord
  REVIEW_STATUS_PENDING = 'pending_review'
  REVIEW_STATUS_APPROVED = 'approved'
  REVIEW_STATUS_REVISION_REQUESTED = 'revision_requested'
  REVIEW_STATUS_REJECTED = 'rejected'

  REVIEWABLE_STATUSES = [REVIEW_STATUS_PENDING, REVIEW_STATUS_APPROVED, REVIEW_STATUS_REVISION_REQUESTED, REVIEW_STATUS_REJECTED].freeze

  # Customer-facing approval gate (separate from the dealer review_status above).
  # Only populated when the company setting project_management.require_client_approval
  # is enabled AND the assignable is a ProjectPhaseTask. When enabled the customer is
  # gate 1 (approve / reject / revise) and the dealer remains the closing gate 2.
  CLIENT_REVIEW_PENDING = 'pending'
  CLIENT_REVIEW_APPROVED = 'approved'
  CLIENT_REVIEW_REVISION_REQUESTED = 'revision_requested'
  CLIENT_REVIEW_REJECTED = 'rejected'

  CLIENT_REVIEW_STATUSES = [
    CLIENT_REVIEW_PENDING, CLIENT_REVIEW_APPROVED,
    CLIENT_REVIEW_REVISION_REQUESTED, CLIENT_REVIEW_REJECTED
  ].freeze

  # FK column was renamed contractor_id -> vendor_id in the unify-vendors migration.
  # Existing callers reference contractor_id; alias keeps them working.
  alias_attribute :contractor_id, :vendor_id

  belongs_to :contractor, foreign_key: :vendor_id
  belongs_to :assignable, polymorphic: true
  belongs_to :company
  belongs_to :assigned_by, class_name: 'User', optional: true
  belongs_to :reviewed_by, class_name: 'User', optional: true
  belongs_to :acted_on_behalf_by, class_name: 'User', optional: true

  has_many :work_logs, class_name: 'AssignmentWorkLog', dependent: :destroy

  validates :status, inclusion: { in: %w[assigned accepted in_progress completed declined] }

  after_commit :notify_on_assignment, on: :create
  after_commit :notify_on_review_changes, on: :update
  after_commit :notify_on_client_review_changes, on: :update

  def submit_for_review!(summary: nil, photos: [])
    unless status.in?(%w[in_progress completed]) || review_status == REVIEW_STATUS_REVISION_REQUESTED
      raise StandardError, "Cannot submit for review from current status: #{status} / review: #{review_status}"
    end

    # Determine whether the customer must approve this work before the dealer closes it.
    # Decided at submit time so later changes to the company setting don't rewrite history.
    requires_client = client_approval_enabled?

    update!(
      review_status: REVIEW_STATUS_PENDING,
      submitted_for_review_at: Time.current,
      completion_summary: summary.presence || completion_summary,
      completion_photos: photos.present? ? photos : completion_photos,
      status: 'completed',
      completed_at: completed_at || Time.current,
      revision_count: review_status == REVIEW_STATUS_REVISION_REQUESTED ? (revision_count || 0) + 1 : (revision_count || 0),
      client_review_required: requires_client,
      client_review_status: requires_client ? CLIENT_REVIEW_PENDING : nil,
      client_reviewed_at: nil,
      client_review_notes: nil,
      acted_on_behalf_by_id: nil
    )
  end

  # Customer approves the work (gate 1). Does NOT close the task — the dealer still
  # does the final confirm via approve_review!. Notification to the dealer fires from
  # the after_commit hook below.
  def client_approve!(notes: nil, acting_dealer: nil)
    raise StandardError, "Customer approval is not required for this assignment" unless client_review_required?
    raise StandardError, "Can only approve while customer review is pending" unless client_review_status == CLIENT_REVIEW_PENDING

    update!(
      client_review_status: CLIENT_REVIEW_APPROVED,
      client_reviewed_at: Time.current,
      client_review_notes: notes.presence || client_review_notes,
      acted_on_behalf_by_id: acting_dealer&.id
    )
  end

  # Customer requests a revision (gate 1). Reopens the task so the contractor can redo it,
  # mirroring the dealer revision path but without a User reviewer.
  def client_request_revision!(notes:, acting_dealer: nil)
    raise StandardError, "Customer approval is not required for this assignment" unless client_review_required?
    raise StandardError, "Can only request revision while customer review is pending" unless client_review_status == CLIENT_REVIEW_PENDING
    raise StandardError, "Revision notes are required" if notes.blank?

    update!(
      client_review_status: CLIENT_REVIEW_REVISION_REQUESTED,
      client_reviewed_at: Time.current,
      client_review_notes: notes,
      acted_on_behalf_by_id: acting_dealer&.id,
      review_status: REVIEW_STATUS_REVISION_REQUESTED,
      revision_notes: notes,
      status: 'in_progress'
    )
  end

  # Customer rejects the work (gate 1). Like a revision it reopens the task, but is recorded
  # as a rejection rather than a revision request.
  def client_reject!(notes: nil, acting_dealer: nil)
    raise StandardError, "Customer approval is not required for this assignment" unless client_review_required?
    raise StandardError, "Can only reject while customer review is pending" unless client_review_status == CLIENT_REVIEW_PENDING

    update!(
      client_review_status: CLIENT_REVIEW_REJECTED,
      client_reviewed_at: Time.current,
      client_review_notes: notes.presence || client_review_notes,
      acted_on_behalf_by_id: acting_dealer&.id,
      review_status: REVIEW_STATUS_REVISION_REQUESTED,
      revision_notes: notes.presence || 'Rejected by customer',
      status: 'in_progress'
    )
  end

  # Dealer acts on the customer's behalf (e.g. customer approved verbally / in person, or
  # never responds). Allowed any time while the customer gate is still pending. A note is
  # REQUIRED so there's a record of why the dealer overrode the customer step.
  def act_on_behalf!(dealer:, decision:, note:)
    raise StandardError, "Customer approval is not required for this assignment" unless client_review_required?
    raise StandardError, "Customer review is no longer pending" unless client_review_status == CLIENT_REVIEW_PENDING
    raise StandardError, "A note is required when acting on the customer's behalf" if note.blank?

    case decision.to_s
    when 'approve'
      client_approve!(notes: note, acting_dealer: dealer)
    when 'request_revision'
      client_request_revision!(notes: note, acting_dealer: dealer)
    when 'reject'
      client_reject!(notes: note, acting_dealer: dealer)
    else
      raise StandardError, "Unknown decision: #{decision.inspect} (expected approve, request_revision, or reject)"
    end
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

  def client_review_pending?
    client_review_required? && client_review_status == CLIENT_REVIEW_PENDING
  end

  def client_review_approved?
    client_review_status == CLIENT_REVIEW_APPROVED
  end

  # True when the dealer should be prompted to do the final confirm: customer has
  # approved (gate 1 cleared) but the dealer review is still pending (gate 2 open).
  def awaiting_dealer_final_confirm?
    client_review_approved? && review_status == REVIEW_STATUS_PENDING
  end

  private

  # Reads the company-level toggle Setting.get('company', company_id, 'project_management')
  # => { 'require_client_approval' => true/false }. Only ProjectPhaseTask assignments are
  # ever gated; service tickets and other assignables stay dealer-only.
  #
  # A task that is NOT visible_to_client can never be customer-approved: the customer
  # cannot see it on the public progress page, so a customer gate would be a dead end
  # (stuck "awaiting customer" forever). For hidden tasks we skip the gate entirely and
  # fall back to the dealer-only flow, regardless of the company setting.
  def client_approval_enabled?
    return false unless assignable_type == 'ProjectPhaseTask'
    return false unless assignable&.visible_to_client

    # The task's PHASE must also be client-visible. A visible task inside a hidden
    # phase never renders on the client's progress view, so a customer gate there
    # would email the customer yet leave them with nothing to approve (stuck
    # "awaiting customer"). Hidden phase => skip the gate, dealer-only flow.
    phase = assignable.project_phase rescue nil
    return false unless phase&.visible_to_client

    cfg = Setting.get('company', company_id, 'project_management')
    return false if cfg.blank?

    # Setting values are JSON-deserialized; tolerate string or symbol keys.
    flag = cfg.is_a?(Hash) ? (cfg['require_client_approval'] || cfg[:require_client_approval]) : false
    ActiveModel::Type::Boolean.new.cast(flag) || false
  rescue => e
    Rails.logger.error("[ContractorAssignment] Failed to read project_management setting: #{e.message}")
    false
  end

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
    # Assigned with "notify" unchecked: the dealer wants the vendor on the
    # ticket now and will send when they're ready. Resend still works on demand.
    return if notification_skipped_at.present?

    # Service tickets go out immediately. The debounce below exists to
    # consolidate bulk project-phase assignments and to leave a window for
    # undoing an accidental one — neither applies to a service ticket, which is
    # assigned deliberately, one at a time, by someone standing there expecting
    # the vendor to hear about it. A ten-minute wait just reads as "it didn't
    # send", which is exactly how it was reported.
    if assignable_type == 'ServiceTicket'
      ContractorAssignmentNotifierJob.perform_later(contractor_id)
      return
    end

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
      # When the customer is gate 1, the contractor's submission goes to the
      # CUSTOMER first, not the dealer. notify_on_client_review_changes handles
      # that path. Skip the dealer review-submitted announcement/email here so
      # the dealer isn't prompted to confirm before the customer has weighed in.
      return if client_review_required? && client_review_status == CLIENT_REVIEW_PENDING

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

  # Fires when the customer-approval gate changes state. Separate from
  # notify_on_review_changes (which watches the dealer review_status) so the two
  # gates notify independently and cleanly.
  #
  #   nil -> pending              : contractor submitted; ask the CUSTOMER to review
  #   pending -> approved         : customer (or dealer on their behalf) approved;
  #                                 prompt the dealer to do the final confirm
  #   pending -> revision/rejected: customer pushed back; tell the contractor to redo
  #                                 and notify the dealer
  def notify_on_client_review_changes
    return unless saved_change_to_client_review_status?

    case client_review_status
    when CLIENT_REVIEW_PENDING
      ProjectNotificationService.notify_client_review_requested(self)
    when CLIENT_REVIEW_APPROVED
      ProjectNotificationService.notify_client_approved(self)
    when CLIENT_REVIEW_REVISION_REQUESTED, CLIENT_REVIEW_REJECTED
      ProjectNotificationService.notify_client_rejected(self)
    end
  rescue => e
    Rails.logger.error("[ContractorAssignment] Notification error on client review change: #{e.message}")
  end

  def resolve_project_id
    return nil unless assignable_type == 'ProjectPhaseTask'
    assignable&.project_phase&.project_id
  rescue
    nil
  end
end
