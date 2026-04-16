class CreateExportJobs < ActiveRecord::Migration[8.0]
  def change
    create_table :export_jobs do |t|
      t.references :company, null: false, foreign_key: true, index: true
      t.references :user, null: false, foreign_key: true, index: true
      t.string  :module_type, null: false
      t.string  :status, null: false, default: 'pending'
      t.string  :format, null: false, default: 'csv'
      t.jsonb   :filters, default: {}, null: false
      t.jsonb   :selected_fields, default: [], null: false
      t.integer :row_count, default: 0, null: false
      t.string  :file_url
      t.datetime :started_at
      t.datetime :completed_at
      t.timestamps
    end

    add_index :export_jobs, :module_type
    add_index :export_jobs, :status
  end
end
