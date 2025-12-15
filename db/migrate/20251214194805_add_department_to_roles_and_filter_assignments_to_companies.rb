class AddDepartmentToRolesAndFilterAssignmentsToCompanies < ActiveRecord::Migration[8.0]
  def change
    # Add department column to roles for filtering users by department
    add_column :roles, :department, :string, comment: 'Department category for role filtering (service, sales, finance, crm, operations)'
    add_index :roles, :department
    
    # Add filter_assignments_by_role flag to companies
    add_column :companies, :filter_assignments_by_role, :boolean, default: false, null: false, comment: 'When true, users can only be assigned to records within their role department'
  end
end
