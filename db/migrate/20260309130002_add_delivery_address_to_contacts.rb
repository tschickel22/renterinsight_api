class AddDeliveryAddressToContacts < ActiveRecord::Migration[8.0]
  def change
    add_column :contacts, :delivery_street, :string unless column_exists?(:contacts, :delivery_street)
    add_column :contacts, :delivery_city, :string unless column_exists?(:contacts, :delivery_city)
    add_column :contacts, :delivery_state, :string unless column_exists?(:contacts, :delivery_state)
    add_column :contacts, :delivery_zip, :string unless column_exists?(:contacts, :delivery_zip)
    add_column :contacts, :delivery_country, :string unless column_exists?(:contacts, :delivery_country)
  end
end
