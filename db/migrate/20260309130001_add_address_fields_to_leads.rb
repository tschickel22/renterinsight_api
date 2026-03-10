class AddAddressFieldsToLeads < ActiveRecord::Migration[8.0]
  def change
    add_column :leads, :street, :string unless column_exists?(:leads, :street)
    add_column :leads, :city, :string unless column_exists?(:leads, :city)
    add_column :leads, :state, :string unless column_exists?(:leads, :state)
    add_column :leads, :zip, :string unless column_exists?(:leads, :zip)
    add_column :leads, :country, :string unless column_exists?(:leads, :country)
  end
end
