# frozen_string_literal: true

# Phase 3 batch 1: schema gaps that prevent QB sync from working correctly.
#
#  * vendors and purchase_orders were missing quickbooks_id/synced_at columns,
#    so the sync handlers would crash on update_column(:quickbooks_id, ...).
#  * companies.quickbooks_realm_id had a plain index — no DB guarantee that
#    two companies can't accidentally end up sharing the same QB realm, which
#    would misroute webhooks.
class QbBatch1SchemaFixes < ActiveRecord::Migration[8.0]
  def change
    add_column :vendors, :quickbooks_id,         :string
    add_column :vendors, :quickbooks_synced_at,  :datetime
    add_index  :vendors, :quickbooks_id, where: 'quickbooks_id IS NOT NULL'

    add_column :purchase_orders, :quickbooks_id,        :string
    add_column :purchase_orders, :quickbooks_synced_at, :datetime
    add_index  :purchase_orders, :quickbooks_id, where: 'quickbooks_id IS NOT NULL'

    # Partial-unique so multiple companies can be "not connected" (NULL) but
    # any two connections must land on different QB realms.
    remove_index :companies, :quickbooks_realm_id, if_exists: true
    add_index    :companies, :quickbooks_realm_id,
                 unique: true,
                 where: 'quickbooks_realm_id IS NOT NULL',
                 name: 'idx_companies_unique_qb_realm'
  end
end
