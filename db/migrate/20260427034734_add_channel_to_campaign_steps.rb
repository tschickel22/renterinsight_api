class AddChannelToCampaignSteps < ActiveRecord::Migration[8.0]
  def change
    add_column :campaign_steps, :channel, :string, null: false, default: 'email'
    add_column :campaign_steps, :sms_body, :text
    add_column :campaign_steps, :media_url, :string
    reversible do |dir|
      dir.up do
        execute "UPDATE campaign_steps SET channel = 'email' WHERE channel IS NULL"
      end
    end
  end
end
