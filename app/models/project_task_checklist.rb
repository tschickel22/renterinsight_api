# frozen_string_literal: true

class ProjectTaskChecklist < ApplicationRecord
  belongs_to :project_task
  has_many :items, class_name: 'ProjectTaskChecklistItem', dependent: :destroy

  validates :title, presence: true

  scope :ordered, -> { order(:position) }

  def completion_percentage
    total = items.count
    return 0 if total == 0
    ((items.where(completed: true).count.to_f / total) * 100).round
  end
end
