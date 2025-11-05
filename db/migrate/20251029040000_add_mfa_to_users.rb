# frozen_string_literal: true

class AddMfaToUsers < ActiveRecord::Migration[8.0]
  def change
    # Add MFA fields only if they don't exist
    unless column_exists?(:users, :mfa_enabled)
      add_column :users, :mfa_enabled, :boolean, default: false
    end
    
    unless column_exists?(:users, :mfa_secret)
      add_column :users, :mfa_secret, :string
    end
    
    unless column_exists?(:users, :mfa_backup_codes)
      add_column :users, :mfa_backup_codes, :json, default: []
    end
    
    unless column_exists?(:users, :mfa_verified_at)
      add_column :users, :mfa_verified_at, :datetime
    end
    
    # Add index
    unless index_exists?(:users, :mfa_enabled)
      add_index :users, :mfa_enabled
    end
  end
end
