# frozen_string_literal: true

class CreateCashReceiptApplications < ActiveRecord::Migration[8.0]
  def change
    create_table :cash_receipt_applications do |t|
      t.references :cash_receipt, null: false, foreign_key: { on_delete: :cascade }
      t.references :invoice, null: false, foreign_key: true
      t.decimal :amount_applied, precision: 12, scale: 2, null: false
      t.timestamps
    end

    add_index :cash_receipt_applications, [:cash_receipt_id, :invoice_id], unique: true, name: 'idx_cra_unique_receipt_invoice'
  end
end
