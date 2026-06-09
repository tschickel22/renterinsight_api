# frozen_string_literal: true

# Per-company manufacturer contact (the dealer's own rep at that factory). These
# are tenant-isolated overrides — the global manufacturer record holds the default
# factory contact, and each company can store their personal rep here. Warranty
# claims prefer the company override, falling back to the global contact.
class AddContactFieldsToCompanyManufacturers < ActiveRecord::Migration[8.0]
  def change
    add_column :company_manufacturers, :contact_name, :string unless column_exists?(:company_manufacturers, :contact_name)
    add_column :company_manufacturers, :contact_email, :string unless column_exists?(:company_manufacturers, :contact_email)
    add_column :company_manufacturers, :contact_phone, :string unless column_exists?(:company_manufacturers, :contact_phone)
  end
end
