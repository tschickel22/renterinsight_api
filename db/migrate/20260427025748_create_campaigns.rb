class CreateCampaigns < ActiveRecord::Migration[8.0]
  def change
    create_table :campaigns do |t|
      t.bigint :company_id, null: false
      t.bigint :location_id
      t.bigint :created_by_user_id, null: false
      t.string :name, null: false
      t.text :description
      t.string :status, null: false, default: 'draft'
      t.string :campaign_type, null: false
      t.string :audience_mode, null: false, default: 'static'
      t.datetime :audience_snapshot_at
      t.string :from_identity_type, null: false
      t.bigint :from_identity_id, null: false
      t.string :from_display_name
      t.string :reply_to_address
      t.string :subject_default
      t.jsonb :goal_config, default: {}, null: false
      t.jsonb :reply_handling, default: {}, null: false
      t.jsonb :send_window, default: {}, null: false
      t.integer :throttle_per_day, default: 500, null: false
      t.string :utm_source
      t.string :utm_medium
      t.string :utm_campaign
      t.datetime :scheduled_at
      t.string :recurrence_cron
      t.jsonb :trigger_config, default: {}, null: false
      t.datetime :started_at
      t.datetime :completed_at
      t.jsonb :stats_cache, default: {}, null: false
      t.boolean :is_deleted, default: false, null: false
      t.bigint :seeded_from_template_id
      t.bigint :generated_from_ai_generation_id
      t.timestamps
    end
    add_index :campaigns, [:company_id, :status]
    add_index :campaigns, [:campaign_type, :status]
    add_index :campaigns, :from_identity_type
  end
end
