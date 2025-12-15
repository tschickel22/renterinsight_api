class AddDepartmentColumnToRoles < ActiveRecord::Migration[8.0]
  def up
    # Only add the column if it doesn't already exist
    unless column_exists?(:roles, :department)
      add_column :roles, :department, :string, comment: 'Department category for role filtering (service, sales, finance, crm, operations)'
      add_index :roles, :department
    end
    
    unless column_exists?(:companies, :filter_assignments_by_role)
      add_column :companies, :filter_assignments_by_role, :boolean, default: false, null: false, comment: 'When true, users can only be assigned to records within their role department'
    end
  end
  
  def down
    remove_column :roles, :department if column_exists?(:roles, :department)
    remove_column :companies, :filter_assignments_by_role if column_exists?(:companies, :filter_assignments_by_role)
  end
end
