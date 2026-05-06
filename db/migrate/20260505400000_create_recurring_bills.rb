# frozen_string_literal: true

class CreateRecurringBills < ActiveRecord::Migration[8.0]
  def change
    create_table :recurring_bills do |t|
      t.references :company, null: false, foreign_key: true
      t.string :name, null: false
      t.references :supplier, foreign_key: true, null: true
      t.references :contact, foreign_key: true, null: true
      t.decimal :amount, precision: 15, scale: 2, null: false
      t.string :frequency, null: false
      t.date :next_due_date, null: false
      t.date :end_date
      t.references :expense_account, foreign_key: { to_table: :chart_of_accounts }, null: false
      t.references :payment_account, foreign_key: { to_table: :chart_of_accounts }, null: true
      t.string :posting_type, default: 'ap'
      t.boolean :auto_post, default: false
      t.boolean :is_active, default: true
      t.string :memo
      t.string :invoice_number_pattern
      t.references :location, foreign_key: true, null: true
      t.string :department
      t.datetime :last_generated_at
      t.integer :generated_count, default: 0
      t.timestamps
    end

    add_index :recurring_bills, [:company_id, :is_active]
    add_index :recurring_bills, :next_due_date
  end
end
