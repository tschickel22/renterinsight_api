class AddCampaignSendIdToCommunications < ActiveRecord::Migration[8.0]
  def change
    add_column :communications, :campaign_send_id, :bigint unless column_exists?(:communications, :campaign_send_id)
    add_index :communications, :campaign_send_id unless index_exists?(:communications, :campaign_send_id)
  end
end
