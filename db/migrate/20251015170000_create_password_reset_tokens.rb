# frozen_string_literal: true

class CreatePasswordResetTokens < ActiveRecord::Migration[8.0]
  def change
    create_table :password_reset_tokens do |t|
      t.string :token_digest, null: false
      t.string :identifier, null: false # email or phone
      t.string :user_type, null: false # 'client' or 'admin'
      t.integer :user_id
      t.string :delivery_method, null: false # 'email' or 'sms'
      t.datetime :expires_at, null: false
      t.boolean :used, default: false
      t.string :ip_address
      t.string :user_agent
      t.integer :attempts, default: 0
      t.timestamps
    end

    add_index :password_reset_tokens, :token_digest, unique: true
    add_index :password_reset_tokens, [:identifier, :created_at]
    add_index :password_reset_tokens, [:user_id, :user_type]
    add_index :password_reset_tokens, :expires_at
  end
end
