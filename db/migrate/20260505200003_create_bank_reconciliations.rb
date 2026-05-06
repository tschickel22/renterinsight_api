# frozen_string_literal: true

class CreateBankReconciliations < ActiveRecord::Migration[8.0]
  def change
    create_table :bank_reconciliations do |t|
      t.references :company, null: false, foreign_key: true
      t.references :bank_account, null: false, foreign_key: true
      t.date :statement_date, null: false
      t.decimal :statement_ending_balance, precision: 15, scale: 2, null: false
      t.decimal :beginning_balance, precision: 15, scale: 2, null: false
      t.decimal :cleared_deposits, precision: 15, scale: 2, default: 0
      t.decimal :cleared_payments, precision: 15, scale: 2, default: 0
      t.decimal :calculated_balance, precision: 15, scale: 2, default: 0
      t.decimal :difference, precision: 15, scale: 2, default: 0
      t.string :status, default: 'in_progress'
      t.datetime :completed_at
      t.references :completed_by, foreign_key: { to_table: :users }, null: true
      t.text :notes
      t.timestamps
    end

    add_index :bank_reconciliations, [:bank_account_id, :statement_date]
    add_index :bank_reconciliations, [:company_id, :status]
  end
end
