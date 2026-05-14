# frozen_string_literal: true

class CreateBills < ActiveRecord::Migration[8.0]
  def change
    create_table :bills do |t|
      t.references :company, null: false, foreign_key: true
      t.references :supplier, foreign_key: true
      t.references :contact, foreign_key: true
      t.references :location, foreign_key: true
      t.string :bill_number
      t.string :vendor_name
      t.date :bill_date, null: false
      t.date :due_date
      t.string :status, default: 'draft', null: false
      t.decimal :subtotal, precision: 12, scale: 2, default: 0
      t.decimal :tax_amount, precision: 12, scale: 2, default: 0
      t.decimal :total_amount, precision: 12, scale: 2, default: 0
      t.decimal :amount_paid, precision: 12, scale: 2, default: 0
      t.decimal :balance_due, precision: 12, scale: 2, default: 0
      t.string :payment_terms
      t.text :memo
      t.text :notes
      t.string :reference_number
      t.jsonb :attachments, default: []
      t.references :ap_account, foreign_key: { to_table: :chart_of_accounts }
      t.references :journal_entry, foreign_key: true
      t.references :payment_journal_entry, foreign_key: { to_table: :journal_entries }
      t.references :created_by, foreign_key: { to_table: :users }
      t.boolean :is_deleted, default: false, null: false
      t.timestamps
    end

    add_index :bills, [:company_id, :bill_number], unique: true, where: "bill_number IS NOT NULL"
    add_index :bills, [:company_id, :status]
    add_index :bills, [:company_id, :due_date]
  end
end
