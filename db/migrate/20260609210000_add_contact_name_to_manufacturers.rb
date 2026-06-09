# frozen_string_literal: true

# The global manufacturers table already has contact_email/contact_phone (the
# factory's default warranty contact). Add contact_name to round it out.
class AddContactNameToManufacturers < ActiveRecord::Migration[8.0]
  def change
    add_column :manufacturers, :contact_name, :string unless column_exists?(:manufacturers, :contact_name)
  end
end
