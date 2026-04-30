class CreateCampaignSends < ActiveRecord::Migration[8.0]
  def change
    create_table :campaign_sends do |t|
      t.bigint :company_id, null: false
      t.bigint :campaign_id, null: false
      t.bigint :campaign_step_id, null: false
      t.bigint :campaign_enrollment_id, null: false
      t.bigint :communication_id
      t.datetime :sent_at
      t.datetime :delivered_at
      t.datetime :opened_at
      t.integer :open_count, default: 0, null: false
      t.datetime :clicked_at
      t.integer :click_count, default: 0, null: false
      t.datetime :replied_at
      t.datetime :bounced_at
      t.string :bounce_type
      t.datetime :unsubscribed_at
      t.datetime :goal_met_at
      t.jsonb :inventory_vehicle_ids, default: [], null: false
      t.jsonb :metadata, default: {}, null: false
      t.timestamps
    end
    add_index :campaign_sends, [:campaign_id, :sent_at]
    add_index :campaign_sends, :campaign_enrollment_id
    add_index :campaign_sends, :communication_id
    add_index :campaign_sends, :company_id
    add_foreign_key :campaign_sends, :campaigns
    add_foreign_key :campaign_sends, :campaign_steps
    add_foreign_key :campaign_sends, :campaign_enrollments
  end
end
