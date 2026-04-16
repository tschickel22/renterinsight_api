class CreateWorkflowRunSteps < ActiveRecord::Migration[8.0]
  def change
    create_table :workflow_run_steps do |t|
      t.references :workflow_run, null: false, foreign_key: true, index: true
      t.string :step_id, null: false
      t.string :step_type, null: false
      t.string :status, null: false
      t.jsonb :input, default: {}
      t.jsonb :output, default: {}
      t.jsonb :error, default: {}
      t.integer :duration_ms
      t.datetime :started_at
      t.datetime :completed_at
      t.timestamps
    end
  end
end
