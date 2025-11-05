# frozen_string_literal: true

class ChangeUsersDefaultStatusToPending < ActiveRecord::Migration[8.0]
  def up
    # Change default status from 'active' to 'pending'
    change_column_default :users, :status, from: 'active', to: 'pending'
    
    # Optional: Update existing pending users who were incorrectly set to active
    # Uncomment if you want to fix existing records that have invitation_token but are active
    # User.where.not(invitation_token: nil).where(status: 'active').update_all(status: 'pending')
  end

  def down
    # Revert back to 'active' as default
    change_column_default :users, :status, from: 'pending', to: 'active'
  end
end
