class AddAddressesToQuotes < ActiveRecord::Migration[8.0]
  def change
    add_column :quotes, :billing_street, :string unless column_exists?(:quotes, :billing_street)
    add_column :quotes, :billing_city, :string unless column_exists?(:quotes, :billing_city)
    add_column :quotes, :billing_state, :string unless column_exists?(:quotes, :billing_state)
    add_column :quotes, :billing_zip, :string unless column_exists?(:quotes, :billing_zip)
    add_column :quotes, :billing_country, :string unless column_exists?(:quotes, :billing_country)

    add_column :quotes, :delivery_street, :string unless column_exists?(:quotes, :delivery_street)
    add_column :quotes, :delivery_city, :string unless column_exists?(:quotes, :delivery_city)
    add_column :quotes, :delivery_state, :string unless column_exists?(:quotes, :delivery_state)
    add_column :quotes, :delivery_zip, :string unless column_exists?(:quotes, :delivery_zip)
    add_column :quotes, :delivery_country, :string unless column_exists?(:quotes, :delivery_country)

    # Add proper jsonb custom_field_values (quotes currently has json custom_fields)
    add_column :quotes, :custom_field_values, :jsonb, default: {}, null: false unless column_exists?(:quotes, :custom_field_values)
  end
end
