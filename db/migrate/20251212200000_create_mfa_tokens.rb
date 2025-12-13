# frozen_string_literal: true

class CreateMfaTokens < ActiveRecord::Migration[8.0]
  def change
    # Create MFA tokens table (similar to password_reset_tokens pattern)
    create_table :mfa_tokens do |t|
      t.string :token_digest, null: false
      t.references :user, polymorphic: true, null: false
      t.string :delivery_method, null: false # 'email' or 'sms'
      t.string :identifier # actual email/phone used for delivery
      t.datetime :expires_at, null: false
      t.datetime :used_at
      t.integer :attempts, default: 0, null: false
      t.string :ip_address
      t.string :user_agent
      t.timestamps
    end

    # Indexes for performance and security
    add_index :mfa_tokens, :token_digest, unique: true
    add_index :mfa_tokens, [:user_id, :user_type, :used_at]
    add_index :mfa_tokens, :expires_at
    add_index :mfa_tokens, :identifier
    add_index :mfa_tokens, :created_at

    # Add MFA fields to buyer_portal_accesses if they don't exist
    unless column_exists?(:buyer_portal_accesses, :mfa_enabled)
      add_column :buyer_portal_accesses, :mfa_enabled, :boolean, default: false
    end

    unless column_exists?(:buyer_portal_accesses, :mfa_method)
      add_column :buyer_portal_accesses, :mfa_method, :string # 'email' or 'sms'
    end

    # Add index
    unless index_exists?(:buyer_portal_accesses, :mfa_enabled)
      add_index :buyer_portal_accesses, :mfa_enabled
    end
  end
end
