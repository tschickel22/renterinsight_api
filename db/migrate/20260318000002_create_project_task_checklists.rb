# frozen_string_literal: true

class CreateProjectTaskChecklists < ActiveRecord::Migration[8.0]
  def change
    create_table :project_task_checklists do |t|
      t.references :project_task, null: false, foreign_key: true
      t.string :title, null: false
      t.integer :position, default: 0

      t.timestamps
    end

    add_index :project_task_checklists, [:project_task_id, :position]
  end
end
