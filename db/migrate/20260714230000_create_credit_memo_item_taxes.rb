# frozen_string_literal: true

# Parallel to InvoiceItemTax — snapshots the per-jurisdiction tax
# contribution on a credit memo line so a return of an invoice that had
# compound multi-jurisdiction tax reverses the same breakdown.
class CreateCreditMemoItemTaxes < ActiveRecord::Migration[8.0]
  def change
    create_table :credit_memo_item_taxes do |t|
      t.references :credit_memo_item, null: false, foreign_key: true
      t.references :tax_code,         null: false, foreign_key: true
      t.decimal    :computed_amount,  precision: 12, scale: 4, null: false, default: 0
      t.decimal    :computed_rate,    precision: 8,  scale: 5, null: false, default: 0
      t.decimal    :taxable_base,     precision: 12, scale: 4, null: false, default: 0
      t.timestamps
    end

    add_index :credit_memo_item_taxes,
              [:credit_memo_item_id, :tax_code_id],
              unique: true,
              name: 'idx_credit_memo_item_taxes_unique_pair'
  end
end
