# frozen_string_literal: true

# Allow companies to add their own manufacturers (not only platform-managed ones).
#   company_id NULL  = global / platform-managed (shared, seeded)
#   company_id set   = company-owned (created/imported by that dealer)
# Code uniqueness becomes per-scope so a company's custom code can't collide with
# its own others or the global set, while still allowing different companies to
# reuse a code.
class AddCompanyIdToManufacturers < ActiveRecord::Migration[8.0]
  def change
    add_column :manufacturers, :company_id, :bigint unless column_exists?(:manufacturers, :company_id)
    add_index :manufacturers, :company_id unless index_exists?(:manufacturers, :company_id)

    if index_exists?(:manufacturers, :code, name: 'index_manufacturers_on_code')
      remove_index :manufacturers, name: 'index_manufacturers_on_code'
    end
    unless index_exists?(:manufacturers, [:company_id, :code], name: 'index_manufacturers_on_company_id_and_code')
      add_index :manufacturers, [:company_id, :code], unique: true, where: 'code IS NOT NULL',
                name: 'index_manufacturers_on_company_id_and_code'
    end
  end
end
