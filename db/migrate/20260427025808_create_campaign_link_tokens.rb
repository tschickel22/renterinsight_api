class CreateCampaignLinkTokens < ActiveRecord::Migration[8.0]
  def change
    create_table :campaign_link_tokens do |t|
      t.bigint :campaign_id, null: false
      t.bigint :campaign_send_id, null: false
      t.string :token, null: false
      t.text :target_url, null: false
      t.integer :click_count, default: 0, null: false
      t.datetime :first_clicked_at
      t.datetime :last_clicked_at
      t.timestamps
    end
    add_index :campaign_link_tokens, :token, unique: true
    add_index :campaign_link_tokens, :campaign_send_id
  end
end
