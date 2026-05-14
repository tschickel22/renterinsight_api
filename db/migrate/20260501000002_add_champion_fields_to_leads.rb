# frozen_string_literal: true

# Add Champion Retailer API fields to the leads table.
#
# These columns allow RenterInsight to track which leads came from Champion's
# lead distribution system and manage the accept/decline workflow.
class AddChampionFieldsToLeads < ActiveRecord::Migration[8.0]
  def change
    change_table :leads, bulk: true do |t|
      # Champion's unique ID for this lead (Salesforce ID format: 18 chars)
      t.string   :champion_salesforce_id

      # Champion's lead status: new | active | declined
      t.string   :champion_status

      # Raw JSON payload from Champion (full lead data for debugging/display)
      t.jsonb    :champion_lead_data, default: {}

      # Which feed config imported this lead
      t.bigint   :champion_config_id

      # Accept/decline timestamps
      t.datetime :champion_accepted_at
      t.datetime :champion_declined_at
    end

    add_index :leads, :champion_salesforce_id
    add_index :leads, [:company_id, :champion_salesforce_id],
              unique: true,
              name: 'idx_leads_company_champion_sf_id'
    add_index :leads, :champion_config_id
  end
end
