# frozen_string_literal: true

class CreateBankReconciliationItems < ActiveRecord::Migration[8.0]
  def change
    create_table :bank_reconciliation_items do |t|
      t.references :bank_reconciliation, null: false, foreign_key: true
      t.references :journal_entry_line, null: false, foreign_key: true
      t.boolean :cleared, default: false
      t.date :cleared_date
      t.decimal :amount, precision: 15, scale: 2, null: false
      t.timestamps
    end

    add_index :bank_reconciliation_items, [:bank_reconciliation_id, :cleared], name: 'idx_recon_items_cleared'
  end
end
