class CreateWorkflowEvents < ActiveRecord::Migration[8.0]
  def change
    create_table :workflow_events do |t|
      t.references :company, null: false, foreign_key: true, index: true
      t.string :event_type, null: false, index: true
      t.string :entity_type
      t.bigint :entity_id
      t.jsonb :payload, default: {}
      t.datetime :dispatched_at, index: true
      t.jsonb :dispatch_error, default: {}
      t.timestamps
    end
    add_index :workflow_events, [:company_id, :dispatched_at]
  end
end
