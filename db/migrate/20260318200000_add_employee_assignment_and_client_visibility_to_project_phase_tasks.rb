# frozen_string_literal: true

class AddEmployeeAssignmentAndClientVisibilityToProjectPhaseTasks < ActiveRecord::Migration[8.0]
  def change
    # Employee assignment on tasks
    unless column_exists?(:project_phase_tasks, :assigned_to_id)
      add_column :project_phase_tasks, :assigned_to_id, :bigint
      add_index :project_phase_tasks, :assigned_to_id
      add_foreign_key :project_phase_tasks, :users, column: :assigned_to_id, on_delete: :nullify
    end

    # Client visibility flags
    unless column_exists?(:project_phase_tasks, :visible_to_client)
      add_column :project_phase_tasks, :visible_to_client, :boolean, default: false, null: false
    end

    unless column_exists?(:project_phase_tasks, :client_actionable)
      add_column :project_phase_tasks, :client_actionable, :boolean, default: false, null: false
    end

    unless column_exists?(:project_phase_tasks, :client_acknowledged_at)
      add_column :project_phase_tasks, :client_acknowledged_at, :datetime
    end

    unless column_exists?(:project_phase_tasks, :client_acknowledged_by)
      add_column :project_phase_tasks, :client_acknowledged_by, :string
    end

    # Template tasks also get visibility defaults so new projects inherit them
    unless column_exists?(:project_template_phase_tasks, :visible_to_client)
      add_column :project_template_phase_tasks, :visible_to_client, :boolean, default: false, null: false
    end

    unless column_exists?(:project_template_phase_tasks, :client_actionable)
      add_column :project_template_phase_tasks, :client_actionable, :boolean, default: false, null: false
    end
  end
end
