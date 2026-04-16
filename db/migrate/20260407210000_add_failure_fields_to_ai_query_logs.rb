class AddFailureFieldsToAiQueryLogs < ActiveRecord::Migration[7.1]
  def change
    add_column :ai_query_logs, :action_name,           :string
    add_column :ai_query_logs, :failure_reason,        :string
    add_column :ai_query_logs, :entity_name_searched,  :string
    add_column :ai_query_logs, :entity_type_attempted, :string
    add_column :ai_query_logs, :user_question,         :text
    add_column :ai_query_logs, :resolved_intent,       :string
    add_column :ai_query_logs, :disambiguate_count,    :integer

    add_index :ai_query_logs, :failure_reason
    add_index :ai_query_logs, :action_name
  end
end
