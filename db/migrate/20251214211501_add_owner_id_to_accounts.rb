class AddOwnerIdToAccounts < ActiveRecord::Migration[8.0]
  def change
    # Accounts already has owner_id column - skip migration
    # This migration kept for consistency but does nothing
  end
end
