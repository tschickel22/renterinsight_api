# frozen_string_literal: true

# Separate the warranty-claim submission target from the relationship rep.
#   claim_email / claim_contact_name = where warranty claims are actually sent
#   contact_name/email/phone (existing) = the account/relationship rep
# Added at both the global (factory default) and per-company (dealer override)
# levels.
class AddClaimContactToManufacturers < ActiveRecord::Migration[8.0]
  def change
    add_column :manufacturers, :claim_email, :string unless column_exists?(:manufacturers, :claim_email)
    add_column :manufacturers, :claim_contact_name, :string unless column_exists?(:manufacturers, :claim_contact_name)

    add_column :company_manufacturers, :claim_email, :string unless column_exists?(:company_manufacturers, :claim_email)
    add_column :company_manufacturers, :claim_contact_name, :string unless column_exists?(:company_manufacturers, :claim_contact_name)
  end
end
