# frozen_string_literal: true

class CreateProjectTasks < ActiveRecord::Migration[8.0]
  def change
    create_table :project_tasks do |t|
      t.references :company, null: false, foreign_key: true
      t.references :project, null: false, foreign_key: true
      t.references :project_phase, null: false, foreign_key: true
      t.references :assigned_to, foreign_key: { to_table: :users }

      t.string :title, null: false
      t.text :description
      t.string :status, default: 'pending'
      t.string :priority, default: 'medium'
      t.integer :position, default: 0
      t.date :due_date
      t.date :started_at
      t.date :completed_at
      t.decimal :estimated_hours, precision: 8, scale: 2
      t.decimal :actual_hours, precision: 8, scale: 2
      t.decimal :estimated_cost, precision: 10, scale: 2
      t.decimal :actual_cost, precision: 10, scale: 2
      t.string :task_type
      t.boolean :is_deleted, default: false
      t.jsonb :metadata, default: {}

      t.timestamps
    end

    add_index :project_tasks, [:project_phase_id, :position]
    add_index :project_tasks, [:project_id, :status]
    add_index :project_tasks, [:company_id, :is_deleted]
  end
end
