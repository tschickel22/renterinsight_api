# frozen_string_literal: true

class CreateProjectTaskDependencies < ActiveRecord::Migration[8.0]
  def change
    create_table :project_task_dependencies do |t|
      t.references :task, null: false, foreign_key: { to_table: :project_tasks }
      t.references :depends_on, null: false, foreign_key: { to_table: :project_tasks }
      t.string :dependency_type, default: 'finish_to_start'

      t.timestamps
    end

    add_index :project_task_dependencies, [:task_id, :depends_on_id], unique: true,
              name: 'idx_task_deps_unique'
  end
end
