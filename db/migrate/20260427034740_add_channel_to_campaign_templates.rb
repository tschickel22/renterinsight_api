class AddChannelToCampaignTemplates < ActiveRecord::Migration[8.0]
  def change
    add_column :campaign_templates, :channel, :string, null: false, default: 'email'
    reversible do |dir|
      dir.up do
        execute "UPDATE campaign_templates SET channel = 'email' WHERE channel IS NULL"
      end
    end
  end
end
