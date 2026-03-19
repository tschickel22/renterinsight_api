# frozen_string_literal: true

class ProjectTaskChecklistItem < ApplicationRecord
  belongs_to :project_task_checklist
  belongs_to :completed_by, class_name: 'User', optional: true

  validates :title, presence: true

  scope :ordered, -> { order(:position) }

  def toggle!
    if completed?
      update!(completed: false, completed_at: nil, completed_by: nil)
    else
      update!(completed: true, completed_at: Time.current)
    end
  end
end
