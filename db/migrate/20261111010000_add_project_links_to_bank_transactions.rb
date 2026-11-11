# E99: what a bank feed line was booked to, so the feed can show it and a
# rule can file spending to a job.
class AddProjectLinksToBankTransactions < ActiveRecord::Migration[8.0]
  def change
    add_column :bank_transactions, :project_id, :bigint
    add_column :bank_transactions, :project_phase_id, :bigint
    add_column :bank_transactions, :vendor_id, :bigint
    add_column :bank_transactions, :deal_id, :bigint
    add_column :bank_transactions, :invoice_id, :bigint
    add_column :bank_transactions, :cash_receipt_id, :bigint
    add_index :bank_transactions, :project_id
    add_index :bank_transactions, :deal_id

    add_column :bank_rules, :assign_project_id, :bigint
  end
end
