class AddEmailSettingsToUsers < ActiveRecord::Migration[8.0]
  def change
    add_column :users, :email_username, :string
    add_column :users, :email_password, :string
    add_column :users, :smtp_server, :string
    add_column :users, :smtp_port, :integer, default: 587
    
    add_index :users, :email_username
  end
end
