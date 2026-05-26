class AddAttachmentsToCampaignSteps < ActiveRecord::Migration[8.0]
  def change
    add_column :campaign_steps, :attachments, :jsonb, default: []
  end
end
