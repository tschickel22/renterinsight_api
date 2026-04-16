class CreateWorkflowSubscriptions < ActiveRecord::Migration[8.0]
  def change
    create_table :workflow_subscriptions do |t|
      t.references :company, null: false, foreign_key: true, index: true
      t.references :workflow_rule, null: false, foreign_key: true, index: true
      t.string :event_type, null: false, index: true
      t.string :entity_type_filter
      t.timestamps
    end
    add_index :workflow_subscriptions, [:company_id, :event_type]
  end
end
