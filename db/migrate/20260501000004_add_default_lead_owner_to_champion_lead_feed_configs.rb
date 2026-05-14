# frozen_string_literal: true

class AddDefaultLeadOwnerToChampionLeadFeedConfigs < ActiveRecord::Migration[8.0]
  def change
    add_reference :champion_lead_feed_configs, :default_lead_owner,
                  foreign_key: { to_table: :users }, null: true, index: true
  end
end
