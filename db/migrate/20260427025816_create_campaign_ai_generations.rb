class CreateCampaignAiGenerations < ActiveRecord::Migration[8.0]
  def change
    create_table :campaign_ai_generations do |t|
      t.bigint :company_id, null: false
      t.bigint :user_id, null: false
      t.bigint :campaign_id
      t.text :prompt, null: false
      t.jsonb :context_snapshot, default: {}, null: false
      t.bigint :template_id_used
      t.jsonb :generated_plan, default: {}, null: false
      t.string :status, null: false, default: 'generated'
      t.bigint :parent_generation_id
      t.string :model_version
      t.integer :input_tokens
      t.integer :output_tokens
      t.bigint :ai_query_log_id
      t.timestamps
    end
    add_index :campaign_ai_generations, [:company_id, :created_at]
    add_index :campaign_ai_generations, :user_id
    add_index :campaign_ai_generations, :campaign_id
  end
end
