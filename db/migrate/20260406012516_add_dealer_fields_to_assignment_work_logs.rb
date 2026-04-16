# frozen_string_literal: true

class AddDealerFieldsToAssignmentWorkLogs < ActiveRecord::Migration[8.0]
  def change
    unless column_exists?(:assignment_work_logs, :user_id)
      add_column :assignment_work_logs, :user_id, :bigint
      add_index :assignment_work_logs, :user_id
    end

    unless column_exists?(:assignment_work_logs, :author_type)
      add_column :assignment_work_logs, :author_type, :string, default: 'contractor'
    end

    unless column_exists?(:assignment_work_logs, :author_name)
      add_column :assignment_work_logs, :author_name, :string
    end

    change_column_null :assignment_work_logs, :contractor_id, true
  end
end
