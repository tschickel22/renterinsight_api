# frozen_string_literal: true

class AddAccountingFieldsToBankAccounts < ActiveRecord::Migration[8.0]
  def change
    add_reference :bank_accounts, :chart_of_account, foreign_key: true, null: true

    add_column :bank_accounts, :stripe_customer_id, :string
    add_column :bank_accounts, :stripe_fc_account_id, :string
    add_column :bank_accounts, :stripe_fc_status, :string
    add_column :bank_accounts, :stripe_fc_last_synced_at, :datetime

    add_column :bank_accounts, :current_balance, :decimal, precision: 15, scale: 2
    add_column :bank_accounts, :institution_name, :string
    add_column :bank_accounts, :account_mask, :string
    add_column :bank_accounts, :currency, :string, default: 'USD'
    add_column :bank_accounts, :opening_balance, :decimal, precision: 15, scale: 2
    add_column :bank_accounts, :opened_on, :date

    add_column :bank_accounts, :check_printing_enabled, :boolean, default: false
    add_column :bank_accounts, :check_number, :integer, default: 0
    add_column :bank_accounts, :check_format, :string
    add_column :bank_accounts, :check_company_name, :string
    add_column :bank_accounts, :check_company_street, :string
    add_column :bank_accounts, :check_company_city, :string
    add_column :bank_accounts, :check_company_state, :string
    add_column :bank_accounts, :check_company_zip, :string
    add_column :bank_accounts, :check_signor_name, :string
    add_column :bank_accounts, :check_bank_name, :string

    add_index :bank_accounts, :stripe_fc_account_id, unique: true, where: "stripe_fc_account_id IS NOT NULL"
    add_index :bank_accounts, :stripe_fc_status
  end
end
