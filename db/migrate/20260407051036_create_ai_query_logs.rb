class CreateAiQueryLogs < ActiveRecord::Migration[8.0]
  def change
    create_table :ai_query_logs do |t|
      t.bigint :company_id
      t.bigint :user_id
      t.bigint :location_id
      t.string :feature
      t.string :module_key
      t.text :question
      t.jsonb :generated_params, default: {}
      t.string :execution_status, default: 'success'
      t.integer :result_count
      t.integer :input_tokens
      t.integer :output_tokens
      t.integer :cost_cents
      t.integer :response_time_ms
      t.text :error_message

      t.timestamps
    end

    add_index :ai_query_logs, [:company_id, :feature, :created_at]
    add_index :ai_query_logs, [:company_id, :module_key]
  end
end
