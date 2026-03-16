# frozen_string_literal: true

class AddProjectPhaseTasks < ActiveRecord::Migration[8.0]
  def change
    # Tasks defined on a template phase (the blueprint)
    create_table :project_template_phase_tasks do |t|
      t.references :project_template_phase, null: false, foreign_key: true
      t.string  :name,       null: false
      t.integer :position,   null: false, default: 0
      t.boolean :is_required, default: false
      t.timestamps
    end
    add_index :project_template_phase_tasks, [:project_template_phase_id, :position],
              name: 'idx_template_phase_tasks_phase_position'

    # Actual task instances on a live project phase
    create_table :project_phase_tasks do |t|
      t.references :project_phase, null: false, foreign_key: true
      t.references :company,       null: false, foreign_key: true
      t.string  :name,             null: false
      t.integer :position,         null: false, default: 0
      t.string  :status,           null: false, default: 'pending'  # pending / completed
      t.boolean :is_required,      default: false
      t.datetime :completed_at
      t.references :completed_by,  foreign_key: { to_table: :users }, null: true
      t.timestamps
    end
    add_index :project_phase_tasks, [:project_phase_id, :position],
              name: 'idx_project_phase_tasks_phase_position'
  end
end
