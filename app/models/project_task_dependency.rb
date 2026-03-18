# frozen_string_literal: true

class ProjectTaskDependency < ApplicationRecord
  belongs_to :task, class_name: 'ProjectTask'
  belongs_to :depends_on, class_name: 'ProjectTask'

  validates :dependency_type, inclusion: { in: %w[finish_to_start start_to_start] }
  validate :no_circular_dependency
  validate :same_project

  private

  def no_circular_dependency
    return unless task_id && depends_on_id

    if task_id == depends_on_id
      errors.add(:base, 'A task cannot depend on itself')
      return
    end

    visited = Set.new([task_id])
    queue = [depends_on_id]

    while queue.any?
      current_id = queue.shift
      if visited.include?(current_id)
        errors.add(:base, 'Circular dependency detected')
        return
      end
      visited.add(current_id)

      ProjectTaskDependency.where(task_id: current_id).pluck(:depends_on_id).each do |dep_id|
        queue << dep_id
      end
    end
  end

  def same_project
    return unless task && depends_on
    if task.project_id != depends_on.project_id
      errors.add(:base, 'Dependencies must be within the same project')
    end
  end
end
