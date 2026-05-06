# frozen_string_literal: true

class CreateRecurringJournalEntries < ActiveRecord::Migration[8.0]
  def change
    create_table :recurring_journal_entries do |t|
      t.references :company, null: false, foreign_key: true
      t.string :name, null: false
      t.string :frequency, null: false
      t.date :next_run_date
      t.date :end_date
      t.jsonb :template_lines, default: []
      t.boolean :auto_post, default: false
      t.boolean :is_active, default: true
      t.datetime :last_run_at
      t.text :memo
      t.timestamps
    end

    add_index :recurring_journal_entries, [:company_id, :is_active]
    add_index :recurring_journal_entries, :next_run_date
  end
end
