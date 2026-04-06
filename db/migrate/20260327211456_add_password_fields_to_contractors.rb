class AddPasswordFieldsToContractors < ActiveRecord::Migration[8.0]
  def change
    add_column :contractors, :password_digest, :string
    add_column :contractors, :password_login_enabled, :boolean, default: false
  end
end
