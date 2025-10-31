class AddTemplateTypeToCommunicationTemplates < ActiveRecord::Migration[8.0]
  def change
    add_column :communication_templates, :template_type, :string, default: 'general'
    add_column :communication_templates, :scope_type, :string # Platform or Company
    add_column :communication_templates, :scope_id, :bigint # Company ID if company-scoped
    
    add_index :communication_templates, :template_type
    add_index :communication_templates, [:scope_type, :scope_id]
    add_index :communication_templates, [:template_type, :channel, :scope_type, :scope_id], 
              name: 'idx_comm_templates_type_channel_scope'
  end
end
