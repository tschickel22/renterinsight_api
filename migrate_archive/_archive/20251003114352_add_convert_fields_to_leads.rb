class AddConvertFieldsToLeads20251003114352 < ActiveRecord::Migration[7.1]
  def change
    add_column :leads, :converted_account_id, :bigint unless column_exists?(:leads, :converted_account_id)
    add_column :leads, :status, :string unless column_exists?(:leads, :status)
    add_index  :leads, :converted_account_id unless index_exists?(:leads, :converted_account_id)
  end
end
