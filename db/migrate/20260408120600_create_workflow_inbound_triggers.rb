class CreateWorkflowInboundTriggers < ActiveRecord::Migration[8.0]
  def change
    create_table :workflow_inbound_triggers do |t|
      t.references :company, null: false, foreign_key: true, index: true
      t.string :token, null: false
      t.string :name, null: false
      t.references :workflow_rule, null: false, foreign_key: true, index: true
      t.boolean :active, default: true
      t.datetime :last_triggered_at
      t.timestamps
    end
    add_index :workflow_inbound_triggers, :token, unique: true
  end
end
