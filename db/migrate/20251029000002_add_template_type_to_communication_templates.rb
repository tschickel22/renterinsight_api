class AddTemplateTypeToCommunicationTemplates < ActiveRecord::Migration[8.0]
  def change
    # Add columns only if they don't exist
    unless column_exists?(:communication_templates, :template_type)
      add_column :communication_templates, :template_type, :string, default: 'general'
    end
    
    unless column_exists?(:communication_templates, :scope_type)
      add_column :communication_templates, :scope_type, :string # Platform or Company
    end
    
    unless column_exists?(:communication_templates, :scope_id)
      add_column :communication_templates, :scope_id, :bigint # Company ID if company-scoped
    end
    
    # Add indexes only if they don't exist
    unless index_exists?(:communication_templates, :template_type)
      add_index :communication_templates, :template_type
    end
    
    unless index_exists?(:communication_templates, [:scope_type, :scope_id])
      add_index :communication_templates, [:scope_type, :scope_id]
    end
    
    unless index_exists?(:communication_templates, [:template_type, :channel, :scope_type, :scope_id], 
                        name: 'idx_comm_templates_type_channel_scope')
      add_index :communication_templates, [:template_type, :channel, :scope_type, :scope_id], 
                name: 'idx_comm_templates_type_channel_scope'
    end
  end
end
