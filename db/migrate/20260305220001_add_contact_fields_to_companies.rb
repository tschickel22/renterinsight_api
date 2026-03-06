class AddContactFieldsToCompanies < ActiveRecord::Migration[8.0]
  def change
    add_column :companies, :phone, :string unless column_exists?(:companies, :phone)
    add_column :companies, :email, :string unless column_exists?(:companies, :email)
    add_column :companies, :address_line1, :string unless column_exists?(:companies, :address_line1)
    add_column :companies, :address_line2, :string unless column_exists?(:companies, :address_line2)
    add_column :companies, :city, :string unless column_exists?(:companies, :city)
    add_column :companies, :state, :string unless column_exists?(:companies, :state)
    add_column :companies, :zip_code, :string unless column_exists?(:companies, :zip_code)
    add_column :companies, :country, :string, default: 'US' unless column_exists?(:companies, :country)
  end
end
