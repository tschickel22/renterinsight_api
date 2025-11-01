# frozen_string_literal: true

class UpdateCommunicationTemplatesForUserInvitations < ActiveRecord::Migration[8.0]
  def up
    # Add company_id column if it doesn't exist
    add_column :communication_templates, :company_id, :integer unless column_exists?(:communication_templates, :company_id)
    
    # Rename columns to match new schema
    rename_column :communication_templates, :subject_template, :subject if column_exists?(:communication_templates, :subject_template)
    rename_column :communication_templates, :body_template, :body if column_exists?(:communication_templates, :body_template)
    rename_column :communication_templates, :active, :is_active if column_exists?(:communication_templates, :active)
    
    # Populate template_type for existing records before indexing
    # This ensures no NULL values in the indexed column
    execute <<-SQL
      UPDATE communication_templates 
      SET template_type = 'legacy_template' 
      WHERE template_type IS NULL OR template_type = ''
    SQL
    
    # Add indexes (now safe because template_type is populated)
    add_index :communication_templates, [:template_type, :channel] unless index_exists?(:communication_templates, [:template_type, :channel])
    add_index :communication_templates, :company_id unless index_exists?(:communication_templates, :company_id)
    add_index :communication_templates, :is_active unless index_exists?(:communication_templates, :is_active)
  end

  def down
    rename_column :communication_templates, :subject, :subject_template if column_exists?(:communication_templates, :subject)
    rename_column :communication_templates, :body, :body_template if column_exists?(:communication_templates, :body)
    rename_column :communication_templates, :is_active, :active if column_exists?(:communication_templates, :is_active)
    remove_column :communication_templates, :company_id if column_exists?(:communication_templates, :company_id)
  end
end
