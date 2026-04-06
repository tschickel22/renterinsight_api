# frozen_string_literal: true

class CreateAssignmentWorkLogs < ActiveRecord::Migration[8.0]
  def change
    create_table :assignment_work_logs do |t|
      t.bigint :contractor_assignment_id, null: false
      t.bigint :contractor_id, null: false
      t.text :note
      t.string :log_type, default: 'note'
      t.jsonb :attachments, default: []
      t.datetime :logged_at

      t.timestamps
    end

    add_index :assignment_work_logs, :contractor_assignment_id
    add_index :assignment_work_logs, :contractor_id
    add_foreign_key :assignment_work_logs, :contractor_assignments
    add_foreign_key :assignment_work_logs, :contractors
  end
end
