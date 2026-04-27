class AddEmailInvalidToLeadsAndContacts < ActiveRecord::Migration[8.0]
  def change
    unless column_exists?(:leads, :email_invalid)
      add_column :leads, :email_invalid, :boolean, default: false, null: false
    end
    unless column_exists?(:contacts, :email_invalid)
      add_column :contacts, :email_invalid, :boolean, default: false, null: false
    end
  end
end
