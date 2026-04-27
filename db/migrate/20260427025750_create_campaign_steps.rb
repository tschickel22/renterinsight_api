class CreateCampaignSteps < ActiveRecord::Migration[8.0]
  def change
    create_table :campaign_steps do |t|
      t.bigint :campaign_id, null: false
      t.integer :position, null: false, default: 0
      t.integer :wait_days, default: 0, null: false
      t.integer :wait_hours, default: 0, null: false
      t.string :subject
      t.string :preheader
      t.jsonb :body_blocks, default: [], null: false
      t.jsonb :inventory_block_config
      t.boolean :is_active, default: true, null: false
      t.timestamps
    end
    add_index :campaign_steps, [:campaign_id, :position]
    add_foreign_key :campaign_steps, :campaigns
  end
end
