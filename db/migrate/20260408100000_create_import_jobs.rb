class CreateImportJobs < ActiveRecord::Migration[8.0]
  def change
    create_table :import_jobs do |t|
      t.references :company, null: false, foreign_key: true, index: true
      t.references :user, null: false, foreign_key: true, index: true
      t.string  :module_type, null: false
      t.string  :status, null: false, default: 'pending'
      t.string  :source_filename
      t.string  :source_file_url
      t.string  :image_zip_url
      t.integer :total_rows, default: 0, null: false
      t.integer :processed_rows, default: 0, null: false
      t.integer :success_count, default: 0, null: false
      t.integer :error_count, default: 0, null: false
      t.integer :skipped_count, default: 0, null: false
      t.jsonb   :column_mapping, default: {}, null: false
      t.string  :duplicate_strategy, default: 'skip'
      t.jsonb   :duplicate_match_fields, default: [], null: false
      t.jsonb   :options, default: {}, null: false
      t.jsonb   :error_log, default: [], null: false
      t.jsonb   :created_record_ids, default: [], null: false
      t.jsonb   :updated_record_snapshots, default: [], null: false
      t.datetime :started_at
      t.datetime :completed_at
      t.timestamps
    end

    add_index :import_jobs, :module_type
    add_index :import_jobs, :status
    add_index :import_jobs, [:company_id, :module_type, :status]
  end
end
