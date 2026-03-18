# frozen_string_literal: true

class ProjectTask < ApplicationRecord
  belongs_to :company
  belongs_to :project
  belongs_to :project_phase
  belongs_to :assigned_to, class_name: 'User', optional: true

  has_many :checklists, class_name: 'ProjectTaskChecklist', dependent: :destroy
  has_many :dependencies, class_name: 'ProjectTaskDependency', foreign_key: :task_id, dependent: :destroy
  has_many :dependents, class_name: 'ProjectTaskDependency', foreign_key: :depends_on_id, dependent: :destroy

  validates :title, presence: true
  validates :status, inclusion: { in: %w[pending in_progress completed blocked skipped] }
  validates :priority, inclusion: { in: %w[low medium high urgent] }

  scope :active, -> { where(is_deleted: [false, nil]) }
  scope :for_phase, ->(phase_id) { where(project_phase_id: phase_id) }
  scope :ordered, -> { order(:position) }

  after_save :update_phase_completion
  after_save :check_blocked_tasks

  def blocking_tasks
    dependencies.includes(:depends_on).map(&:depends_on).select { |t| t.status != 'completed' }
  end

  def blocked?
    blocking_tasks.any?
  end

  def can_start?
    !blocked? && status == 'pending'
  end

  def complete!
    update!(
      status: 'completed',
      completed_at: Date.current
    )
  end

  private

  def update_phase_completion
    return unless saved_change_to_status?

    phase = project_phase
    total = phase.tasks.active.count
    completed = phase.tasks.active.where(status: 'completed').count

    if total > 0
      percentage = ((completed.to_f / total) * 100).round
      phase.update_column(:completion_percentage, percentage) if phase.has_attribute?(:completion_percentage)
    end

    project.recalculate_completion! if project.respond_to?(:recalculate_completion!)
  end

  def check_blocked_tasks
    return unless saved_change_to_status? && status == 'completed'

    dependents.includes(:task).each do |dep|
      task = dep.task
      if task.status == 'blocked' && !task.blocked?
        task.update_column(:status, 'pending')
      end
    end
  end
end
