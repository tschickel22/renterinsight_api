# frozen_string_literal: true

class CreateJournalEntries < ActiveRecord::Migration[8.0]
  def change
    create_table :journal_entries do |t|
      t.references :company, null: false, foreign_key: true
      t.string :entry_number
      t.date :entry_date, null: false
      t.text :memo
      t.string :source_type, default: 'manual'
      t.string :source_entity_type
      t.bigint :source_entity_id
      t.boolean :is_adjusting, default: false
      t.boolean :is_closing, default: false
      t.boolean :is_void, default: false
      t.datetime :voided_at
      t.references :voided_by, foreign_key: { to_table: :users }
      t.references :posted_by, foreign_key: { to_table: :users }
      t.references :reversed_by, foreign_key: { to_table: :journal_entries }
      t.integer :fiscal_year
      t.integer :fiscal_period
      t.boolean :locked, default: false
      t.timestamps
    end

    add_index :journal_entries, [:company_id, :entry_number], unique: true
    add_index :journal_entries, [:company_id, :entry_date]
    add_index :journal_entries, [:source_entity_type, :source_entity_id]
    add_index :journal_entries, :is_void
    add_index :journal_entries, [:fiscal_year, :fiscal_period]
  end
end
