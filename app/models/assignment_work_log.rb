# frozen_string_literal: true

class AssignmentWorkLog < ApplicationRecord
  # FK column was renamed contractor_id -> vendor_id in the unify-vendors migration.
  alias_attribute :contractor_id, :vendor_id

  belongs_to :contractor_assignment
  belongs_to :contractor, foreign_key: :vendor_id, optional: true
  belongs_to :user, optional: true

  validates :log_type, inclusion: { in: %w[note photo document status_change completion] }
  validates :author_type, inclusion: { in: %w[contractor dealer] }
  validate :must_have_author

  scope :ordered, -> { order(logged_at: :desc, created_at: :desc) }

  after_commit :notify_work_log_added, on: :create

  private

  def must_have_author
    if contractor_id.blank? && user_id.blank?
      errors.add(:base, 'Must have either a contractor or user as author')
    end
  end

  def notify_work_log_added
    return unless contractor_assignment.present?
    return unless author_type == 'contractor'
    return if log_type == 'status_change' # skip auto status entries to reduce noise

    ProjectNotificationService.notify_work_log_added(self, contractor_assignment)
  rescue => e
    Rails.logger.error("[AssignmentWorkLog] Notification error: #{e.message}")
  end
end
