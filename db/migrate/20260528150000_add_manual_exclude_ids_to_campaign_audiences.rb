class AddManualExcludeIdsToCampaignAudiences < ActiveRecord::Migration[8.0]
  def change
    add_column :campaign_audiences, :manual_exclude_ids, :jsonb, default: []
  end
end
