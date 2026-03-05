class AddApplicableToPackageTemplates < ActiveRecord::Migration[8.0]
  def change
    add_column :package_templates, :applicable_to, :string, default: 'all', null: false
    add_index :package_templates, [:company_id, :applicable_to]
  end
end
