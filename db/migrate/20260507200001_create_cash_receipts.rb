# frozen_string_literal: true

class CreateCashReceipts < ActiveRecord::Migration[8.0]
  def change
    create_table :cash_receipts do |t|
      t.references :company, null: false, foreign_key: true, index: true
      t.references :account, foreign_key: true
      t.references :contact, foreign_key: true
      t.references :bank_account, foreign_key: true
      t.references :journal_entry, foreign_key: true
      t.references :location, foreign_key: true
      t.references :created_by, foreign_key: { to_table: :users }
      t.string  :receipt_number
      t.date    :receipt_date, null: false
      t.decimal :amount, precision: 12, scale: 2, null: false
      t.decimal :amount_applied, precision: 12, scale: 2, default: 0
      t.decimal :amount_unapplied, precision: 12, scale: 2, default: 0
      t.string  :payment_method
      t.string  :reference_number
      t.text    :memo
      t.string  :customer_name
      t.string  :status, default: 'posted'
      t.datetime :voided_at
      t.boolean :is_deleted, default: false, null: false
      t.timestamps
    end

    add_index :cash_receipts, [:company_id, :receipt_number], unique: true, where: "receipt_number IS NOT NULL"
    add_index :cash_receipts, [:company_id, :status]
    add_index :cash_receipts, :receipt_date
  end
end
