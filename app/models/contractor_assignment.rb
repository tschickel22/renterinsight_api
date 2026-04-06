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

    # Sync to ProjectPhaseTask
    sync_phase_task_completed! if assignable_type == 'ProjectPhaseTask'
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
end
