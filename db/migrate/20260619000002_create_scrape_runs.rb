class CreateScrapeRuns < ActiveRecord::Migration[8.0]
  def change
    create_table :scrape_runs do |t|
      t.references :catalog_source, null: false, foreign_key: true, index: true
      t.string   :status, null: false, default: 'running'
      t.string   :trigger, null: false, default: 'manual'
      t.datetime :started_at
      t.datetime :finished_at
      t.integer  :homes_discovered, null: false, default: 0
      t.integer  :homes_parsed_ok, null: false, default: 0
      t.integer  :homes_failed, null: false, default: 0
      t.integer  :added_count, null: false, default: 0
      t.integer  :updated_count, null: false, default: 0
      t.integer  :removed_count, null: false, default: 0
      t.integer  :inactivated_count, null: false, default: 0
      t.jsonb    :field_extraction_rates, null: false, default: {}
      t.boolean  :degraded, null: false, default: false
      t.jsonb    :error_log, null: false, default: []
      t.timestamps
    end

    add_index :scrape_runs, [:catalog_source_id, :created_at]
  end
end
