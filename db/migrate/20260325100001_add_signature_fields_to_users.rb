class AddSignatureFieldsToUsers < ActiveRecord::Migration[8.0]
  def change
    add_column :users, :signature_url, :string
    add_column :users, :initials_url, :string
    add_column :users, :typed_signature, :string
    add_column :users, :typed_initials, :string
    add_column :users, :signature_font, :string
  end
end
