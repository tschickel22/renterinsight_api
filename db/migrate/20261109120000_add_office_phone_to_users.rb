# A rep's personal cell went out on a starter play's email signature and
# contact card. Users now keep a mobile (the old phone, still used for sign-in
# codes and alerts), an office number with extension, and which one customers see.
class AddOfficePhoneToUsers < ActiveRecord::Migration[8.0]
  def change
    add_column :users, :office_phone, :string
    add_column :users, :office_phone_ext, :string
    add_column :users, :customer_phone, :string, default: 'mobile', null: false
  end
end
