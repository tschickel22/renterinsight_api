# frozen_string_literal: true
class Reminder < ApplicationRecord
  self.table_name = 'reminders'
  belongs_to :lead

  validates :title, presence: true
  validates :reminder_type, inclusion: { in: %w[call email task follow_up other], allow_nil: true }

  scope :upcoming, -> { where(is_completed: [false, nil]).order(due_date: :asc) }

  def complete!
    update!(is_completed: true)
  end
end
