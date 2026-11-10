# frozen_string_literal: true

# A retailer location that buys from more than one Champion factory gets one
# DIGS key per factory, so a location can have several lead feeds. Replace
# the unique (company, location) index with a plain one. Nothing reads the
# uniqueness, so this is safe while old and new code run side by side.
class AllowSeveralChampionFeedsPerLocation < ActiveRecord::Migration[8.0]
  disable_ddl_transaction!

  def up
    add_index :champion_lead_feed_configs, [:company_id, :location_id],
              name: 'idx_champion_lead_configs_company_loc', algorithm: :concurrently,
              if_not_exists: true
    remove_index :champion_lead_feed_configs, name: 'idx_champion_lead_configs_company_location',
                 algorithm: :concurrently, if_exists: true
  end

  def down
    remove_index :champion_lead_feed_configs, name: 'idx_champion_lead_configs_company_loc',
                 algorithm: :concurrently, if_exists: true
    add_index :champion_lead_feed_configs, [:company_id, :location_id], unique: true,
              name: 'idx_champion_lead_configs_company_location', algorithm: :concurrently
  end
end
