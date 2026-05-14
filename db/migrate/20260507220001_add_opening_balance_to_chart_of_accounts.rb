# frozen_string_literal: true

class AddOpeningBalanceToChartOfAccounts < ActiveRecord::Migration[8.0]
  def change
    add_column :chart_of_accounts, :opening_balance, :decimal, precision: 12, scale: 2, default: 0 unless column_exists?(:chart_of_accounts, :opening_balance)
    add_column :chart_of_accounts, :opening_balance_date, :date unless column_exists?(:chart_of_accounts, :opening_balance_date)
  end
end
