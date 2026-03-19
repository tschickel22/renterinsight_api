# frozen_string_literal: true

class AddTimelineFieldsToProjectPhaseTasks < ActiveRecord::Migration[8.0]
  def change
    # Task-level timeline fields (roll up to phase)
    unless column_exists?(:project_phase_tasks, :estimated_days)
      add_column :project_phase_tasks, :estimated_days, :integer
    end

    unless column_exists?(:project_phase_tasks, :estimated_start_date)
      add_column :project_phase_tasks, :estimated_start_date, :date
    end

    unless column_exists?(:project_phase_tasks, :estimated_completion_date)
      add_column :project_phase_tasks, :estimated_completion_date, :date
    end

    # Template tasks also get timeline defaults
    unless column_exists?(:project_template_phase_tasks, :estimated_days)
      add_column :project_template_phase_tasks, :estimated_days, :integer
    end
  end
end
