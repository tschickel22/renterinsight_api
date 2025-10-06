class AddConvertFieldsToLeads < ActiveRecord::Migration[7.1]
  def change
    #{ '[add_column :leads, :status, :string, default: "new"],' if [ "yes" = "yes" ]; }
    #{ 'add_column :leads, :status, :string, default: "new"' if [ "yes" = "yes" ] }
    #{ 'add_column :leads, :converted_account_id, :bigint' if [ "yes" = "yes" ] }
    #{ 'add_index  :leads, :converted_account_id' if [ "yes" = "yes" ] }
  end
end
