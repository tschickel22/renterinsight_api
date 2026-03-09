class AddIsMasterToAgreementTemplates < ActiveRecord::Migration[8.0]
  def change
    unless column_exists?(:agreement_templates, :is_master)
      add_column :agreement_templates, :is_master, :boolean, default: false, null: false
      add_index :agreement_templates, [:template_group_id, :is_master], name: 'idx_templates_group_master'
    end
  end
end
