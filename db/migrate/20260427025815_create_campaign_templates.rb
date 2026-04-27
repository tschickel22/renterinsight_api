class CreateCampaignTemplates < ActiveRecord::Migration[8.0]
  def change
    create_table :campaign_templates do |t|
      t.bigint :company_id
      t.string :slug, null: false
      t.string :name, null: false
      t.text :description
      t.string :category, null: false
      t.string :vertical, null: false
      t.jsonb :audience_hint, default: {}, null: false
      t.jsonb :steps_template, default: [], null: false
      t.jsonb :goal_config_template, default: {}, null: false
      t.jsonb :send_window_template, default: {}, null: false
      t.boolean :is_seeded, default: false, null: false
      t.boolean :is_active, default: true, null: false
      t.bigint :created_by_user_id
      t.timestamps
    end
    add_index :campaign_templates, [:company_id, :slug], unique: true
    add_index :campaign_templates, :category
    add_index :campaign_templates, :vertical
  end
end
