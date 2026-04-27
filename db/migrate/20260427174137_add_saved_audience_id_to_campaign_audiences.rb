class AddSavedAudienceIdToCampaignAudiences < ActiveRecord::Migration[8.0]
  def change
    add_reference :campaign_audiences, :saved_audience,
                  foreign_key: { to_table: :audiences },
                  index: { name: 'idx_campaign_audiences_saved_audience' }
  end
end
