class CreateCampaignEvents < ActiveRecord::Migration[8.0]
  def change
    create_table :campaign_events do |t|
      t.bigint :company_id, null: false
      t.bigint :campaign_id, null: false
      t.bigint :campaign_enrollment_id
      t.bigint :campaign_send_id
      t.string :event_type, null: false
      t.datetime :occurred_at, null: false
      t.jsonb :payload, default: {}, null: false
      t.timestamps
    end
    add_index :campaign_events, [:campaign_id, :event_type, :occurred_at]
    add_index :campaign_events, :company_id
    add_foreign_key :campaign_events, :campaigns
  end
end
