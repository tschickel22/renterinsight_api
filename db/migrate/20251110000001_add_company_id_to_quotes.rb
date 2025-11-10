# frozen_string_literal: true

class AddCompanyIdToQuotes < ActiveRecord::Migration[8.0]
  def change
    add_column :quotes, :company_id, :integer, null: true
    add_index :quotes, :company_id
    
    # Optional: Add foreign key constraint (uncomment if desired)
    # add_foreign_key :quotes, :companies
  end
end
