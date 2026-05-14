# frozen_string_literal: true

# Champion Lead Feed Configs — stores per-company (or per-location) API token
# configuration for the Champion Retailer Leads API.
#
# Champion issues one API key per retailer location via DIGS.
# A single company may have multiple locations, each with its own key.
# If location_id is NULL, the config applies company-wide.
#
# Endpoints (from Swagger):
#   GET  /api/external/leads/AuthTest     — connection test
#   GET  /api/external/leads/download     — bulk download all leads
#   GET  /api/external/leads              — paginated list
#   GET  /api/external/leads/{id}         — single lead
#   PUT  /api/external/leads/{id}/accept  — accept (reveals contact info)
#   PUT  /api/external/leads/{id}/decline — decline with reason
#   PUT  /api/external/leads/{id}/status  — update status
class CreateChampionLeadFeedConfigs < ActiveRecord::Migration[8.0]
  def change
    create_table :champion_lead_feed_configs do |t|
      t.references :company,  null: false, foreign_key: true, index: true
      t.references :location, foreign_key: true, index: true # nullable = company-wide

      # Encrypted API token (Rails 8 encrypts attribute)
      t.string :api_token_ciphertext, null: false

      # Environment selector (stage vs production)
      t.string :environment, null: false, default: 'production'

      # Champion metadata
      t.string :champion_account_number   # 6-char e.g. "2614TX"
      t.string :retailer_name             # Display name from DIGS

      # Feed control
      t.boolean :active, null: false, default: true

      # Sync tracking
      t.datetime :last_synced_at
      t.datetime :last_sync_error_at
      t.text     :last_sync_error
      t.integer  :total_leads_synced,  default: 0, null: false
      t.integer  :sync_interval_minutes, default: 15, null: false

      # Stats from last sync
      t.jsonb :last_sync_stats, default: {}, null: false # { created, updated, skipped, errors, duration_ms }

      t.timestamps
    end

    add_index :champion_lead_feed_configs, [:company_id, :location_id],
              unique: true,
              name: 'idx_champion_lead_configs_company_location'
    add_index :champion_lead_feed_configs, :active
  end
end
