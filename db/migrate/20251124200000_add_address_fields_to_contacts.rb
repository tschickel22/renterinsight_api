# frozen_string_literal: true

class AddAddressFieldsToContacts < ActiveRecord::Migration[8.0]
  def change
    add_column :contacts, :street, :string
    add_column :contacts, :city, :string
    add_column :contacts, :state, :string
    add_column :contacts, :zip, :string
    add_column :contacts, :country, :string
  end
end
