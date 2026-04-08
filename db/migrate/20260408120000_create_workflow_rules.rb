class CreateWorkflowRules < ActiveRecord::Migration[8.0]
  def change
    create_table :workflow_rules do |t|
      t.references :company, null: false, foreign_key: true, index: true
      t.string :name, null: false
      t.text :description
      t.string :entity_type, null: false, index: true
      t.string :status, null: false, default: 'draft'
      t.bigint :workflow_template_id, index: true
      t.jsonb :trigger, default: {}
      t.jsonb :conditions, default: []
      t.jsonb :steps, default: {}
      t.jsonb :parameters, default: {}
      t.integer :version, default: 1
      t.references :created_by_user, foreign_key: { to_table: :users }, null: true
      t.boolean :is_seeded, default: false
      t.string :halt_on_reply, default: 'false'
      t.timestamps
    end
    add_index :workflow_rules, [:company_id, :status, :entity_type]
  end
end
