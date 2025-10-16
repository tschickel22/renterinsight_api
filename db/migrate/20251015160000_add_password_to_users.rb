# frozen_string_literal: true

class AddPasswordToUsers < ActiveRecord::Migration[8.0]
  def change
    add_column :users, :password_digest, :string
    add_column :users, :role, :string, default: 'staff'
    add_column :users, :first_name, :string
    add_column :users, :last_name, :string
    add_column :users, :status, :string, default: 'active'
    add_column :users, :last_sign_in_at, :datetime
    add_column :users, :permissions, :json, default: []
  end
end
