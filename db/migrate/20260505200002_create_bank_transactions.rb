# frozen_string_literal: true

class CreateBankTransactions < ActiveRecord::Migration[8.0]
  def change
    create_table :bank_transactions do |t|
      t.references :company, null: false, foreign_key: true
      t.references :bank_account, null: false, foreign_key: true
      t.date :transaction_date, null: false
      t.date :post_date
      t.text :description
      t.decimal :amount, precision: 15, scale: 2, null: false
      t.string :reference_number
      t.string :transaction_type
      t.string :fitid
      t.string :stripe_txn_id
      t.string :status, default: 'unmatched'
      t.references :matched_journal_entry, foreign_key: { to_table: :journal_entries }, null: true
      t.datetime :matched_at
      t.string :matched_by
      t.references :category_account, foreign_key: { to_table: :chart_of_accounts }, null: true
      t.references :rule, foreign_key: { to_table: :bank_rules }, null: true
      t.text :excluded_reason
      t.text :memo
      t.references :contact, foreign_key: true, null: true
      t.timestamps
    end

    add_index :bank_transactions, [:bank_account_id, :fitid], unique: true, where: "fitid IS NOT NULL", name: 'idx_bank_txn_fitid_unique'
    add_index :bank_transactions, :stripe_txn_id, unique: true, where: "stripe_txn_id IS NOT NULL"
    add_index :bank_transactions, [:bank_account_id, :status]
    add_index :bank_transactions, :transaction_date
  end
end
