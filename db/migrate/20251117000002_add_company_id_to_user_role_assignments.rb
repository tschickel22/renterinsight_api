# frozen_string_literal: true

# Add company_id to user_role_assignments for better scoping and queries
#
# This column is essential for:
# - Scoping role assignments to specific companies
# - Migration service queries
# - Permission cache invalidation per company
# - Multi-tenant data isolation

class AddCompanyIdToUserRoleAssignments < ActiveRecord::Migration[8.0]
  def change
    add_column :user_role_assignments, :company_id, :bigint
    add_index :user_role_assignments, :company_id
    add_foreign_key :user_role_assignments, :companies, on_delete: :cascade
    
    # Backfill company_id from users table for existing records
    reversible do |dir|
      dir.up do
        execute <<-SQL
          UPDATE user_role_assignments
          SET company_id = users.company_id
          FROM users
          WHERE user_role_assignments.user_id = users.id;
        SQL
      end
    end
    
    # Make company_id NOT NULL after backfill
    change_column_null :user_role_assignments, :company_id, false
  end
end
