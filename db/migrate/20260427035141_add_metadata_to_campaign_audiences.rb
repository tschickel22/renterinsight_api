class AddMetadataToCampaignAudiences < ActiveRecord::Migration[8.0]
  def change
    add_column :campaign_audiences, :metadata, :jsonb, default: {}, null: false
  end
end
