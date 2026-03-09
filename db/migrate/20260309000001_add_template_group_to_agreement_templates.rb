class AddTemplateGroupToAgreementTemplates < ActiveRecord::Migration[8.0]
  def change
    unless column_exists?(:agreement_templates, :template_group_id)
      add_column :agreement_templates, :template_group_id, :string
      add_index :agreement_templates, :template_group_id, name: 'idx_agr_templates_group'
      add_index :agreement_templates, [:template_group_id, :state_code], name: 'idx_agr_templates_group_state', unique: true
    end
  end
end
