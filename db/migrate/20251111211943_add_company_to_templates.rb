# frozen_string_literal: true

class AddCompanyToTemplates < ActiveRecord::Migration[8.0]
  def change
    # Add company_id column
    add_column :templates, :company_id, :bigint
    
    # Add index
    add_index :templates, :company_id
    
    # Add foreign key
    add_foreign_key :templates, :companies
    
    # Backfill existing templates to company_id = 1 (or first company)
    reversible do |dir|
      dir.up do
        # Get first company ID
        result = execute("SELECT id FROM companies ORDER BY id ASC LIMIT 1")
        if result.any?
          first_company_id = result.first['id']
          execute "UPDATE templates SET company_id = #{first_company_id} WHERE company_id IS NULL"
        else
          # If no companies exist, create a default one
          execute "INSERT INTO companies (name, created_at, updated_at) VALUES ('Default Company', NOW(), NOW())"
          result = execute("SELECT id FROM companies ORDER BY id ASC LIMIT 1")
          first_company_id = result.first['id']
          execute "UPDATE templates SET company_id = #{first_company_id} WHERE company_id IS NULL"
        end
      end
    end
    
    # Make company_id NOT NULL after backfill
    change_column_null :templates, :company_id, false
  end
end
