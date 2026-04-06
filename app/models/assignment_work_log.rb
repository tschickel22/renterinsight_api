# frozen_string_literal: true

class AssignmentWorkLog < ApplicationRecord
  belongs_to :contractor_assignment
  belongs_to :contractor, optional: true
  belongs_to :user, optional: true

  validates :log_type, inclusion: { in: %w[note photo document status_change completion] }
  validates :author_type, inclusion: { in: %w[contractor dealer] }
  validate :must_have_author

  scope :ordered, -> { order(logged_at: :desc, created_at: :desc) }

  private

  def must_have_author
    if contractor_id.blank? && user_id.blank?
      errors.add(:base, 'Must have either a contractor or user as author')
    end
  end
end
