# frozen_string_literal: true

class EnhanceCustomFieldsForParts < ActiveRecord::Migration[8.0]
  def change
    # Add new columns to existing custom_fields table for enterprise features
    add_column :custom_fields, :field_key, :string # snake_case version of name for API
    add_column :custom_fields, :description, :text # Help text for users
    add_column :custom_fields, :placeholder, :string # Input placeholder
    add_column :custom_fields, :validation_rules, :jsonb, default: {} # min/max, regex, etc.
    add_column :custom_fields, :is_active, :boolean, default: true
    add_column :custom_fields, :is_system_field, :boolean, default: false # Platform-defined fields
    add_column :custom_fields, :section, :string # Group fields in UI
    add_column :custom_fields, :created_by_id, :bigint
    add_column :custom_fields, :updated_by_id, :bigint
    
    # Add new field types to support all enterprise scenarios
    # Existing: text, number, email, phone, date, select, checkbox
    # New types will be: currency, percent, datetime, multiselect, user, file, url, longtext
    
    # Add indexes for performance
    add_index :custom_fields, [:company_id, :module, :is_active]
    add_index :custom_fields, [:company_id, :module, :section]
    add_index :custom_fields, :field_key
    add_index :custom_fields, :created_by_id
    add_index :custom_fields, :updated_by_id
    
    # Foreign keys
    add_foreign_key :custom_fields, :users, column: :created_by_id
    add_foreign_key :custom_fields, :users, column: :updated_by_id
    
    # Backfill field_key for existing records (if any)
    reversible do |dir|
      dir.up do
        execute <<-SQL
          UPDATE custom_fields 
          SET field_key = LOWER(REPLACE(name, ' ', '_'))
          WHERE field_key IS NULL
        SQL
      end
    end
    
    # Make field_key required after backfill
    change_column_null :custom_fields, :field_key, false
    
    # Add unique constraint on field_key per module per company
    add_index :custom_fields, [:company_id, :module, :field_key], 
              unique: true, 
              name: 'index_custom_fields_on_company_module_field_key'
  end
end
