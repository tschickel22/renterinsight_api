# frozen_string_literal: true

class CreateProjectTaskChecklistItems < ActiveRecord::Migration[8.0]
  def change
    create_table :project_task_checklist_items do |t|
      t.references :project_task_checklist, null: false, foreign_key: true
      t.string :title, null: false
      t.boolean :completed, default: false
      t.integer :position, default: 0
      t.references :completed_by, foreign_key: { to_table: :users }
      t.datetime :completed_at

      t.timestamps
    end

    add_index :project_task_checklist_items, [:project_task_checklist_id, :position],
              name: 'idx_checklist_items_on_checklist_and_position'
  end
end
