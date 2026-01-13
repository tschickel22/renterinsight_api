class AddIsDemoToCompanies < ActiveRecord::Migration[8.0]
  def change
    add_column :companies, :is_demo, :boolean, default: false, null: false
    add_index :companies, :is_demo
  end
end
