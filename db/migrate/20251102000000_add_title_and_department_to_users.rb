class AddTitleAndDepartmentToUsers < ActiveRecord::Migration[8.0]
  def change
    add_column :users, :company_id, :integer unless column_exists?(:users, :company_id)
    add_column :users, :title, :string
    add_column :users, :department, :string
    
    add_index :users, :company_id unless index_exists?(:users, :company_id)
    add_foreign_key :users, :companies, column: :company_id unless foreign_key_exists?(:users, :companies)
  end
end
