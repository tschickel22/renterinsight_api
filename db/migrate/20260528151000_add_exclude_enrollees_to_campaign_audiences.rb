class AddExcludeEnrolleesToCampaignAudiences < ActiveRecord::Migration[8.0]
  def change
    add_column :campaign_audiences, :exclude_active_campaign_enrollees, :boolean, default: false, null: false
    add_column :campaign_audiences, :exclude_active_nurture_enrollees, :boolean, default: false, null: false
  end
end
