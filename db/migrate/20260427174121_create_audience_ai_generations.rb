class CreateAudienceAiGenerations < ActiveRecord::Migration[8.0]
  def change
    create_table :audience_ai_generations do |t|
      t.references :company, null: false, foreign_key: true, index: true
      t.references :user, foreign_key: true, index: true

      t.text :prompt, null: false
      t.jsonb :context_snapshot, default: {}
      t.jsonb :generated_filter_tree, null: false, default: {}

      t.string :status, null: false, default: 'generated'
      t.references :parent_generation, foreign_key: { to_table: :audience_ai_generations }, index: { name: 'idx_audience_ai_gen_parent' }

      t.string :model_version
      t.integer :input_tokens
      t.integer :output_tokens

      t.references :ai_query_log, foreign_key: true, index: { name: 'idx_audience_ai_gen_log' }

      t.string :source_type, null: false

      t.timestamps
    end
  end
end
