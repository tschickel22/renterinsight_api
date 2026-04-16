class CreateWorkflowRuns < ActiveRecord::Migration[8.0]
  def change
    create_table :workflow_runs do |t|
      t.references :company, null: false, foreign_key: true, index: true
      t.references :workflow_rule, null: false, foreign_key: true, index: true
      t.string :entity_type, null: false
      t.bigint :entity_id, null: false
      t.string :status, null: false, default: 'pending'
      t.string :current_step_id
      t.jsonb :variables, default: {}
      t.datetime :wait_until, index: true
      t.string :wait_reason
      t.references :parent_run, foreign_key: { to_table: :workflow_runs }, null: true
      t.jsonb :rule_snapshot, default: {}
      t.datetime :started_at
      t.datetime :completed_at
      t.jsonb :error_details, default: {}
      t.timestamps
    end
    add_index :workflow_runs, [:entity_type, :entity_id]
    add_index :workflow_runs, [:company_id, :status, :wait_until]
  end
end
