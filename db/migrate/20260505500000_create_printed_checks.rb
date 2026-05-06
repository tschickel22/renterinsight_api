# frozen_string_literal: true

class CreatePrintedChecks < ActiveRecord::Migration[8.0]
  def change
    create_table :printed_checks do |t|
      t.references :company, null: false, foreign_key: true
      t.references :bank_account, null: false, foreign_key: true
      t.references :journal_entry, foreign_key: true, null: true
      t.string :status, default: 'queued'
      t.string :paid_to, null: false
      t.decimal :amount, precision: 15, scale: 2, null: false
      t.string :check_number
      t.string :memo
      t.string :description
      t.date :printed_on
      t.references :contact, foreign_key: true, null: true
      t.timestamps
    end

    add_index :printed_checks, [:bank_account_id, :check_number], unique: true, where: "check_number IS NOT NULL"
    add_index :printed_checks, [:company_id, :status]
  end
end
