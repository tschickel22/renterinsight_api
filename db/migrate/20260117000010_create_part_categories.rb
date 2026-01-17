# frozen_string_literal: true

class CreatePartCategories < ActiveRecord::Migration[8.0]
  def up
    # Clean up any orphaned objects
    execute "DROP TABLE IF EXISTS part_categories CASCADE" rescue nil
    
    create_table :part_categories do |t|
      t.bigint :company_id, null: false
      t.string :name, null: false
      t.text :description
      t.bigint :parent_id
      t.boolean :active, default: true
      t.boolean :is_deleted, default: false
      t.datetime :deleted_at
      
      # Custom fields support
      t.jsonb :custom_fields, default: {}
      
      # Audit fields
      t.bigint :created_by_id
      t.bigint :updated_by_id
      t.timestamps
    end
    
    # Add foreign keys
    add_foreign_key :part_categories, :companies, column: :company_id
    add_foreign_key :part_categories, :part_categories, column: :parent_id
    add_foreign_key :part_categories, :users, column: :created_by_id
    add_foreign_key :part_categories, :users, column: :updated_by_id
    
    # Add indexes
    add_index :part_categories, :company_id unless index_exists?(:part_categories, :company_id)
    add_index :part_categories, :parent_id unless index_exists?(:part_categories, :parent_id)
    add_index :part_categories, :created_by_id unless index_exists?(:part_categories, :created_by_id)
    add_index :part_categories, :updated_by_id unless index_exists?(:part_categories, :updated_by_id)
    add_index :part_categories, [:company_id, :name], unique: true, where: "is_deleted = false", name: 'index_part_categories_on_company_id_and_name' unless index_exists?(:part_categories, [:company_id, :name], name: 'index_part_categories_on_company_id_and_name')
    add_index :part_categories, [:company_id, :active], name: 'index_part_categories_on_company_id_and_active' unless index_exists?(:part_categories, [:company_id, :active], name: 'index_part_categories_on_company_id_and_active')
  end
  
  def down
    drop_table :part_categories if table_exists?(:part_categories)
  end
end
