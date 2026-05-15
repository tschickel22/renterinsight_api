class CreateWorkflowAiGenerations < ActiveRecord::Migration[8.0]
  def change
    create_table :workflow_ai_generations do |t|
      t.bigint :company_id, null: false
      t.bigint :user_id, null: false
      t.bigint :workflow_rule_id
      t.bigint :parent_generation_id
      t.bigint :ai_query_log_id
      t.text :prompt, null: false
      t.jsonb :context_snapshot, default: {}, null: false
      t.jsonb :generated_plan, default: {}, null: false
      t.string :status, null: false, default: 'generated'
      t.string :model_version
      t.integer :input_tokens
      t.integer :output_tokens
      t.timestamps
    end
    add_index :workflow_ai_generations, [:company_id, :created_at]
    add_index :workflow_ai_generations, :user_id
    add_index :workflow_ai_generations, :workflow_rule_id
    add_index :workflow_ai_generations, :parent_generation_id
    add_index :workflow_ai_generations, :ai_query_log_id

    add_foreign_key :workflow_ai_generations, :companies
    add_foreign_key :workflow_ai_generations, :users
    add_foreign_key :workflow_ai_generations, :workflow_rules
  end
end
