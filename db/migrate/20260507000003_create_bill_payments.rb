# frozen_string_literal: true

class CreateBillPayments < ActiveRecord::Migration[8.0]
  def change
    create_table :bill_payments do |t|
      t.references :bill, null: false, foreign_key: true
      t.references :company, null: false, foreign_key: true
      t.decimal :amount, precision: 12, scale: 2, null: false
      t.date :payment_date, null: false
      t.string :payment_method
      t.string :check_number
      t.references :bank_account, foreign_key: true
      t.references :chart_of_account, foreign_key: true
      t.references :journal_entry, foreign_key: true
      t.text :memo
      t.references :created_by, foreign_key: { to_table: :users }
      t.timestamps
    end
  end
end
