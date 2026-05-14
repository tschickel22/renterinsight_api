# frozen_string_literal: true

class CreateChartOfAccounts < ActiveRecord::Migration[8.0]
  def change
    create_table :chart_of_accounts do |t|
      t.references :company, null: false, foreign_key: true
      t.string :account_number, null: false
      t.string :name, null: false
      t.string :description
      t.string :account_type, null: false
      t.string :sub_type
      t.string :normal_balance, null: false
      t.references :parent, foreign_key: { to_table: :chart_of_accounts }
      t.boolean :is_header, default: false
      t.boolean :is_active, default: true
      t.boolean :is_system, default: false
      t.string :qbo_account_id
      t.integer :position, default: 0
      t.references :bank_account, foreign_key: true
      t.timestamps
    end

    add_index :chart_of_accounts, [:company_id, :account_number], unique: true
    add_index :chart_of_accounts, [:company_id, :account_type]
    add_index :chart_of_accounts, [:company_id, :parent_id]
    add_index :chart_of_accounts, :is_active
  end
end
