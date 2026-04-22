# frozen_string_literal: true

class CreateSocialPosts < ActiveRecord::Migration[8.0]
  def change
    create_table :social_posts do |t|
      t.bigint :company_id, null: false
      t.bigint :location_id
      t.bigint :social_account_id
      t.bigint :created_by_user_id
      t.bigint :vehicle_id

      t.string :post_type
      t.string :intent_category
      t.string :platform
      t.string :status

      t.text   :caption
      t.string :headline
      t.text   :description

      t.jsonb  :image_urls, default: []
      t.string :cta_type

      t.string :tagged_url
      t.string :utm_campaign
      t.string :utm_content

      t.datetime :scheduled_at
      t.datetime :published_at
      t.string   :external_post_id

      t.integer :lead_count, default: 0
      t.integer :deal_count, default: 0
      t.decimal :attributed_revenue, precision: 12, scale: 2, default: 0

      t.integer :reach
      t.integer :impressions
      t.integer :engagement_count
      t.integer :link_clicks
      t.datetime :metrics_synced_at

      t.boolean :nurture_approved, default: false
      t.bigint  :nurture_sequence_id

      t.string :ai_generation_version
      t.jsonb  :generation_context, default: {}

      t.boolean :is_deleted, default: false

      t.timestamps
    end

    add_index :social_posts, [:company_id, :status]
    add_index :social_posts, [:company_id, :intent_category]
    add_index :social_posts, :vehicle_id
    add_index :social_posts, :created_by_user_id
    add_index :social_posts, :nurture_sequence_id
    add_index :social_posts, :published_at
  end
end
