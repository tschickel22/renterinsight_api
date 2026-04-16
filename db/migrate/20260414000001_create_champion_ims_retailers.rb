# frozen_string_literal: true

# Champion IMS Retailers - stores per-company retailer configurations for
# the Champion Homes Inventory Management System (IMS) feed.
#
# Each row represents one Retailer Navision ID (e.g., "0551KS" = Heartland Homes)
# that a dealer wants to sync into their shared FloorPlan catalog.
#
# Multiple retailers can be configured per company. Sync status is tracked
# per-retailer so one failing feed doesn't hide the state of the others.
class CreateChampionImsRetailers < ActiveRecord::Migration[8.0]
  def change
    create_table :champion_ims_retailers do |t|
      t.references :company, null: false, foreign_key: true, index: true
      t.references :location, foreign_key: true, index: true # nullable - company-wide if null

      # The Navision ID is Champion's identifier for a retailer/dealer location.
      # Format: 4 digits + 2 uppercase letters, e.g. "0551KS".
      t.string :retailer_navision_id, null: false

      # Display metadata (populated from feed response or entered by admin)
      t.string :retailer_name
      t.string :retailer_city
      t.string :retailer_state

      # Feed control
      t.boolean :active, default: true, null: false
      t.string  :sync_frequency, default: 'weekly', null: false # 'weekly' | 'manual'

      # Sync tracking
      t.datetime :last_sync_at
      t.string   :last_sync_status, default: 'pending', null: false # pending | running | success | failed
      t.text     :last_sync_error
      t.jsonb    :last_sync_stats, default: {}, null: false # { added, updated, removed, total, duration_ms }
      t.datetime :next_scheduled_sync_at

      t.timestamps
    end

    add_index :champion_ims_retailers, [:company_id, :retailer_navision_id],
              unique: true,
              name: 'idx_champion_ims_retailers_on_company_and_navision'
    add_index :champion_ims_retailers, :active
    add_index :champion_ims_retailers, :last_sync_status
    add_index :champion_ims_retailers, :next_scheduled_sync_at
  end
end
