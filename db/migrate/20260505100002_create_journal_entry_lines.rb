# frozen_string_literal: true

class CreateJournalEntryLines < ActiveRecord::Migration[8.0]
  def change
    create_table :journal_entry_lines do |t|
      t.references :journal_entry, null: false, foreign_key: true
      t.references :chart_of_account, null: false, foreign_key: true
      t.decimal :debit_amount, precision: 15, scale: 2, default: 0
      t.decimal :credit_amount, precision: 15, scale: 2, default: 0
      t.text :memo
      t.references :location, foreign_key: true
      t.string :department
      t.references :contact, foreign_key: true
      t.references :deal, foreign_key: true
      t.references :vehicle, foreign_key: true
      t.integer :position, default: 0
      t.timestamps
    end

    add_index :journal_entry_lines, :department
  end
end
