# frozen_string_literal: true

# Credit memos are a first-class accounting entity separate from invoices:
# they reduce what a customer owes without recording a cash inflow. Modeled
# with line items (parity with QB CreditMemo) and applications against
# invoices (parity with QB LinkedTxn to Invoice/CustomerBalance).
class CreateCreditMemos < ActiveRecord::Migration[8.0]
  def change
    create_table :credit_memos do |t|
      t.references :company,  null: false, foreign_key: true
      t.references :location, null: false, foreign_key: true
      t.references :contact,  foreign_key: true
      t.string     :credit_memo_number, null: false
      t.date       :memo_date, null: false
      t.string     :status, null: false, default: 'draft'
      t.text       :reason
      t.decimal    :subtotal,         precision: 12, scale: 2, default: 0
      t.decimal    :tax_amount,       precision: 12, scale: 2, default: 0
      t.decimal    :total,            precision: 12, scale: 2, default: 0
      t.decimal    :amount_applied,   precision: 12, scale: 2, default: 0
      t.decimal    :amount_remaining, precision: 12, scale: 2, default: 0
      t.text       :notes
      t.string     :source_type
      t.bigint     :source_id
      t.bigint     :created_by_id
      t.boolean    :is_deleted, default: false, null: false
      t.datetime   :deleted_at
      t.string     :qbo_id
      t.datetime   :qbo_synced_at
      t.timestamps
    end
    add_index :credit_memos, [:company_id, :credit_memo_number], unique: true, name: 'idx_credit_memos_unique_number'
    add_index :credit_memos, [:source_type, :source_id]

    create_table :credit_memo_items do |t|
      t.references :credit_memo, null: false, foreign_key: true
      t.string     :description, null: false
      t.decimal    :quantity, precision: 10, scale: 2, default: 1
      t.decimal    :rate,     precision: 10, scale: 2, null: false
      t.decimal    :amount,   precision: 10, scale: 2, null: false, default: 0
      t.string     :itemable_type
      t.bigint     :itemable_id
      t.boolean    :taxable,  default: false
      t.boolean    :skip_tax, default: false
      t.integer    :position, default: 0
      t.timestamps
    end
    add_index :credit_memo_items, [:itemable_type, :itemable_id]

    create_table :credit_memo_applications do |t|
      t.references :company,     null: false, foreign_key: true
      t.references :credit_memo, null: false, foreign_key: true
      t.references :applicable,  polymorphic: true, null: false
      t.decimal    :amount, precision: 12, scale: 2, null: false
      t.datetime   :applied_at, null: false
      t.bigint     :created_by_id
      t.timestamps
    end
    add_index :credit_memo_applications,
              [:credit_memo_id, :applicable_type, :applicable_id],
              unique: true,
              name: 'idx_credit_memo_applications_unique_pair'
    add_index :credit_memo_applications,
              [:applicable_type, :applicable_id, :company_id],
              name: 'idx_credit_memo_applications_by_target'

    # Track credits separately from payments on the invoice so amount_due
    # equals total - amount_paid - amount_credited.
    add_column :invoices, :amount_credited, :decimal, precision: 10, scale: 2, default: 0
  end
end
