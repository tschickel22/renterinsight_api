class CreateProjectTemplates < ActiveRecord::Migration[8.0]
  def change
    create_table :project_templates do |t|
      t.references :company, null: false, foreign_key: true
      t.references :location, foreign_key: true              # Optional: location-specific templates
      t.string :name, null: false
      t.text :description
      t.string :template_type, default: 'standard'           # standard, land_home, factory_order, used_home, service_project
      t.boolean :is_default, default: false                   # Default template for new projects
      t.boolean :is_active, default: true
      t.boolean :is_deleted, default: false
      t.integer :phase_count, default: 0                      # Cached count of phases
      t.bigint :created_by_id                                 # User who created this template
      t.timestamps
    end

    add_index :project_templates, [:company_id, :is_default], name: 'idx_project_templates_company_default'
    add_index :project_templates, [:company_id, :template_type], name: 'idx_project_templates_company_type'
    add_index :project_templates, [:company_id, :is_active], name: 'idx_project_templates_company_active'
  end
end
