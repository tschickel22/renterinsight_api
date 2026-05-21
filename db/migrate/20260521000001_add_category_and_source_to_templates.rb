class AddCategoryAndSourceToTemplates < ActiveRecord::Migration[8.0]
  def change
    add_column :templates, :category, :string, default: 'general'
    add_column :templates, :source, :string, default: 'manual'
    add_index :templates, :category
    add_index :templates, :source
    add_index :templates, [:company_id, :category]
  end
end
