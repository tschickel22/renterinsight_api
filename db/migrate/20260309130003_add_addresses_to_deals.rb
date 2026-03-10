class AddAddressesToDeals < ActiveRecord::Migration[8.0]
  def change
    add_column :deals, :billing_street, :string unless column_exists?(:deals, :billing_street)
    add_column :deals, :billing_city, :string unless column_exists?(:deals, :billing_city)
    add_column :deals, :billing_state, :string unless column_exists?(:deals, :billing_state)
    add_column :deals, :billing_zip, :string unless column_exists?(:deals, :billing_zip)
    add_column :deals, :billing_country, :string unless column_exists?(:deals, :billing_country)

    add_column :deals, :delivery_street, :string unless column_exists?(:deals, :delivery_street)
    add_column :deals, :delivery_city, :string unless column_exists?(:deals, :delivery_city)
    add_column :deals, :delivery_state, :string unless column_exists?(:deals, :delivery_state)
    add_column :deals, :delivery_zip, :string unless column_exists?(:deals, :delivery_zip)
    add_column :deals, :delivery_country, :string unless column_exists?(:deals, :delivery_country)
  end
end
