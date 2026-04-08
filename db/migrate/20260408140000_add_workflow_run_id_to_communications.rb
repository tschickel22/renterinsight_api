class AddWorkflowRunIdToCommunications < ActiveRecord::Migration[8.0]
  def change
    add_column :communications, :workflow_run_id, :bigint, null: true
    add_index :communications, :workflow_run_id
    add_column :communications, :workflow_step_id, :string, null: true
  end
end
