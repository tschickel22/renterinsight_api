class AddAddressesToInvoices < ActiveRecord::Migration[8.0]
  def change
    add_column :invoices, :billing_street, :string unless column_exists?(:invoices, :billing_street)
    add_column :invoices, :billing_city, :string unless column_exists?(:invoices, :billing_city)
    add_column :invoices, :billing_state, :string unless column_exists?(:invoices, :billing_state)
    add_column :invoices, :billing_zip, :string unless column_exists?(:invoices, :billing_zip)
    add_column :invoices, :billing_country, :string unless column_exists?(:invoices, :billing_country)

    add_column :invoices, :delivery_street, :string unless column_exists?(:invoices, :delivery_street)
    add_column :invoices, :delivery_city, :string unless column_exists?(:invoices, :delivery_city)
    add_column :invoices, :delivery_state, :string unless column_exists?(:invoices, :delivery_state)
    add_column :invoices, :delivery_zip, :string unless column_exists?(:invoices, :delivery_zip)
    add_column :invoices, :delivery_country, :string unless column_exists?(:invoices, :delivery_country)

    add_column :invoices, :custom_field_values, :jsonb, default: {}, null: false unless column_exists?(:invoices, :custom_field_values)
  end
end
