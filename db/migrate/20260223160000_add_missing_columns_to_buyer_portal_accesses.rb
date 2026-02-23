# frozen_string_literal: true

# Fix: buyer_portal_accesses table was created without company_id, role, status,
# permissions, invitation_sent_at, and MFA columns. These were added directly to
# staging DB but never captured in a migration file. This causes 500 errors on
# production/main: PG::UndefinedColumn: column buyer_portal_accesses.company_id does not exist
#
# Migration is idempotent - safe to run on staging (no-op) and production (adds columns).

class AddMissingColumnsToBuyerPortalAccesses < ActiveRecord::Migration[8.0]
  def up
    # Core tenant isolation column
    unless column_exists?(:buyer_portal_accesses, :company_id)
      add_column :buyer_portal_accesses, :company_id, :bigint
      add_index :buyer_portal_accesses, :company_id, name: 'index_buyer_portal_accesses_on_company_id'
      add_index :buyer_portal_accesses, [:buyer_type, :buyer_id, :company_id], name: 'index_buyer_portal_on_buyer_and_company'
    end

    # Portal user management columns
    unless column_exists?(:buyer_portal_accesses, :role)
      add_column :buyer_portal_accesses, :role, :string, default: 'Client'
    end

    unless column_exists?(:buyer_portal_accesses, :status)
      add_column :buyer_portal_accesses, :status, :string, default: 'Pending'
      add_index :buyer_portal_accesses, :status, name: 'index_buyer_portal_accesses_on_status' unless index_exists?(:buyer_portal_accesses, :status)
    end

    unless column_exists?(:buyer_portal_accesses, :permissions)
      add_column :buyer_portal_accesses, :permissions, :json, default: []
    end

    unless column_exists?(:buyer_portal_accesses, :invitation_sent_at)
      add_column :buyer_portal_accesses, :invitation_sent_at, :datetime
    end

    # MFA columns
    unless column_exists?(:buyer_portal_accesses, :mfa_enabled)
      add_column :buyer_portal_accesses, :mfa_enabled, :boolean, default: false
      add_index :buyer_portal_accesses, :mfa_enabled, name: 'index_buyer_portal_accesses_on_mfa_enabled' unless index_exists?(:buyer_portal_accesses, :mfa_enabled)
    end

    unless column_exists?(:buyer_portal_accesses, :mfa_method)
      add_column :buyer_portal_accesses, :mfa_method, :string
    end

    # Backfill company_id from associated contact for existing records
    execute <<-SQL
      UPDATE buyer_portal_accesses
      SET company_id = contacts.company_id
      FROM contacts
      WHERE buyer_portal_accesses.buyer_type = 'Contact'
        AND buyer_portal_accesses.buyer_id = contacts.id
        AND buyer_portal_accesses.company_id IS NULL
    SQL
  end

  def down
    remove_index :buyer_portal_accesses, name: 'index_buyer_portal_accesses_on_mfa_enabled' if index_exists?(:buyer_portal_accesses, name: 'index_buyer_portal_accesses_on_mfa_enabled')
    remove_index :buyer_portal_accesses, name: 'index_buyer_portal_accesses_on_status' if index_exists?(:buyer_portal_accesses, name: 'index_buyer_portal_accesses_on_status')
    remove_index :buyer_portal_accesses, name: 'index_buyer_portal_on_buyer_and_company' if index_exists?(:buyer_portal_accesses, name: 'index_buyer_portal_on_buyer_and_company')
    remove_index :buyer_portal_accesses, name: 'index_buyer_portal_accesses_on_company_id' if index_exists?(:buyer_portal_accesses, name: 'index_buyer_portal_accesses_on_company_id')

    remove_column :buyer_portal_accesses, :mfa_method if column_exists?(:buyer_portal_accesses, :mfa_method)
    remove_column :buyer_portal_accesses, :mfa_enabled if column_exists?(:buyer_portal_accesses, :mfa_enabled)
    remove_column :buyer_portal_accesses, :invitation_sent_at if column_exists?(:buyer_portal_accesses, :invitation_sent_at)
    remove_column :buyer_portal_accesses, :permissions if column_exists?(:buyer_portal_accesses, :permissions)
    remove_column :buyer_portal_accesses, :status if column_exists?(:buyer_portal_accesses, :status)
    remove_column :buyer_portal_accesses, :role if column_exists?(:buyer_portal_accesses, :role)
    remove_column :buyer_portal_accesses, :company_id if column_exists?(:buyer_portal_accesses, :company_id)
  end
end
