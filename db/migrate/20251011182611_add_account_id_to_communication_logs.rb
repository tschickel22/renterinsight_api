class AddAccountIdToCommunicationLogs < ActiveRecord::Migration[7.2]
  def change
    # Add account_id column to communication_logs
    add_column :communication_logs, :account_id, :integer
    add_index :communication_logs, :account_id
    
    # Make lead_id optional (it already is in most setups, but just to be explicit)
    change_column_null :communication_logs, :lead_id, true
    
    # Add foreign key constraint
    add_foreign_key :communication_logs, :accounts, column: :account_id, on_delete: :cascade
  end
end
