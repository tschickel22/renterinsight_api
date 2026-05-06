# frozen_string_literal: true

class CreateAccountingImports < ActiveRecord::Migration[8.0]
  def change
    create_table :accounting_imports do |t|
      t.references :company, null: false, foreign_key: true
      t.references :user, null: false, foreign_key: true
      t.string :source_type, null: false
      t.string :status, default: 'pending'
      t.date :cutover_date
      t.jsonb :import_config, default: {}
      t.jsonb :results, default: {}
      t.jsonb :errors_log, default: []
      t.integer :total_imported, default: 0
      t.integer :total_skipped, default: 0
      t.integer :total_errors, default: 0
      t.text :notes
      t.datetime :started_at
      t.datetime :completed_at
      t.timestamps
    end

    add_index :accounting_imports, [:company_id, :source_type]
    add_index :accounting_imports, :status
  end
end
