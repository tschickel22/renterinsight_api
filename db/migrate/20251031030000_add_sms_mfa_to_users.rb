# frozen_string_literal: true

# Migration to add SMS MFA support alongside existing TOTP MFA
# This is ADDITIVE - we keep all existing TOTP columns:
# - mfa_enabled (boolean)
# - mfa_secret (string) - for TOTP
# - mfa_backup_codes (json)
# - mfa_verified_at (datetime)
#
# We ADD new SMS-specific columns:
# - phone_verified (boolean) - to verify phone ownership
# - mfa_sms_code (string) - temporary SMS verification code
# - mfa_sms_expires_at (datetime) - code expiration
# - mfa_method (string) - 'sms' or 'totp' (default: 'sms')

class AddSmsMfaToUsers < ActiveRecord::Migration[8.0]
  def change
    # Add SMS-specific columns (KEEP all existing TOTP columns)
    add_column :users, :phone_verified, :boolean, default: false, null: false
    add_column :users, :mfa_sms_code, :string
    add_column :users, :mfa_sms_expires_at, :datetime
    add_column :users, :mfa_method, :string, default: 'sms'
    
    # Add indexes for performance
    add_index :users, :phone_verified
    add_index :users, :mfa_sms_expires_at
    add_index :users, :mfa_method
    
    # Existing columns remain untouched:
    # - mfa_enabled
    # - mfa_secret
    # - mfa_backup_codes
    # - mfa_verified_at
    # - phone (already exists)
  end
end
