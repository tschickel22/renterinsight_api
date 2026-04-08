class CreateWorkflowTemplates < ActiveRecord::Migration[7.1]
  def change
    create_table :workflow_templates do |t|
      t.string :key, null: false
      t.string :name, null: false
      t.text :description
      t.string :category, null: false
      t.string :entity_type, null: false
      t.string :icon
      t.text :preview_description
      t.jsonb :required_integrations, default: []
      t.jsonb :trigger, default: {}
      t.jsonb :conditions, default: []
      t.jsonb :steps, default: {}
      t.jsonb :parameters, default: {}
      t.jsonb :parameter_schema, default: []
      t.boolean :is_active, default: true
      t.integer :sort_order, default: 0
      t.integer :version, default: 1
      t.timestamps
    end
    add_index :workflow_templates, :key, unique: true
    add_index :workflow_templates, :category
    add_index :workflow_templates, :is_active
  end
end
