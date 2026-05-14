# frozen_string_literal: true

class CreateAccountingSettings < ActiveRecord::Migration[8.0]
  def change
    create_table :accounting_settings do |t|
      t.references :company, null: false, foreign_key: true, index: { unique: true }
      t.integer :fiscal_year_start_month, default: 1
      t.references :retained_earnings_account, foreign_key: { to_table: :chart_of_accounts }
      t.references :default_ar_account, foreign_key: { to_table: :chart_of_accounts }
      t.references :default_ap_account, foreign_key: { to_table: :chart_of_accounts }
      t.references :default_sales_revenue_account, foreign_key: { to_table: :chart_of_accounts }
      t.references :default_cogs_account, foreign_key: { to_table: :chart_of_accounts }
      t.references :default_sales_tax_payable_account, foreign_key: { to_table: :chart_of_accounts }
      t.references :default_bank_account, foreign_key: { to_table: :bank_accounts }
      t.boolean :auto_post_invoices, default: false
      t.boolean :auto_post_payments, default: false
      t.boolean :auto_post_purchases, default: false
      t.boolean :lock_period_on_close, default: true
      t.integer :check_number_sequence, default: 1
      t.timestamps
    end
  end
end
