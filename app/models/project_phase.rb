# frozen_string_literal: true

class ProjectPhase < ApplicationRecord
  STATUSES = %w[not_started in_progress completed skipped].freeze

  belongs_to :project
  belongs_to :company
  belongs_to :completed_by, class_name: 'User', foreign_key: 'completed_by_id', optional: true

  # Validations
  validates :name, presence: true
  validates :position, presence: true, numericality: { greater_than_or_equal_to: 0 }
  validates :status, presence: true, inclusion: { in: STATUSES }

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

  def overdue?
    return false unless estimated_completion_date
    return false if status.in?(%w[completed skipped])
    estimated_completion_date < Date.current
  end

  def days_until_estimated_completion
    return nil unless estimated_completion_date
    (estimated_completion_date - Date.current).to_i
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

  private

  # ============================================================================
  # NOTIFICATIONS (placeholder — will use existing CommunicationService)
  # ============================================================================

  def send_start_notification!
    # TODO: Wire to CommunicationService when building notification triggers
    # For now, just mark as notified so we don't double-send later
    update_column(:client_notified_start, true)
    Rails.logger.info "[ProjectPhase] Phase '#{name}' started for project #{project_id} — notification queued"
  end

  def send_completion_notification!
    # TODO: Wire to CommunicationService when building notification triggers
    update_column(:client_notified_complete, true)
    Rails.logger.info "[ProjectPhase] Phase '#{name}' completed for project #{project_id} — notification queued"
  end
end
