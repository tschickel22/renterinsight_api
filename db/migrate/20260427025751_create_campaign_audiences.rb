class CreateCampaignAudiences < ActiveRecord::Migration[8.0]
  def change
    create_table :campaign_audiences do |t|
      t.bigint :campaign_id, null: false
      t.string :source_type, null: false
      t.jsonb :filter_tree, default: {}, null: false
      t.jsonb :exclude_filter_tree, default: {}, null: false
      t.integer :estimated_count, default: 0, null: false
      t.datetime :estimated_at
      t.timestamps
    end
    add_index :campaign_audiences, :campaign_id, unique: true
    add_foreign_key :campaign_audiences, :campaigns
  end
end
