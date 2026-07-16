# frozen_string_literal: true

# Phase 3 batch 1: schema gaps that prevent QB sync from working correctly.
#
#  * vendors and purchase_orders were missing quickbooks_id/synced_at columns,
#    so the sync handlers would crash on update_column(:quickbooks_id, ...).
#  * companies.quickbooks_realm_id had a plain index — no DB guarantee that
#    two companies can't accidentally end up sharing the same QB realm, which
#    would misroute webhooks.
#
# Rewritten to be idempotent + self-healing:
#  * Every add_column/add_index is guarded so re-running after a partial
#    failure (staging first attempt died on the unique index) doesn't blow up
#    on "column already exists".
#  * Before adding the unique index, nulls out any duplicate realm_ids —
#    keeping the row with the most recent updated_at, which is the one that
#    most likely reflects the active OAuth connection. Older duplicates are
#    almost always seed/demo leftovers (staging had "Demo Company 1" sharing
#    Summit Park's realm), so nulling them out is safe: those companies
#    become "not connected" and can re-authorize QB fresh if needed.
class QbBatch1SchemaFixes < ActiveRecord::Migration[8.0]
  def up
    unless column_exists?(:vendors, :quickbooks_id)
      add_column :vendors, :quickbooks_id, :string
    end
    unless column_exists?(:vendors, :quickbooks_synced_at)
      add_column :vendors, :quickbooks_synced_at, :datetime
    end
    add_index :vendors, :quickbooks_id, where: 'quickbooks_id IS NOT NULL', if_not_exists: true

    unless column_exists?(:purchase_orders, :quickbooks_id)
      add_column :purchase_orders, :quickbooks_id, :string
    end
    unless column_exists?(:purchase_orders, :quickbooks_synced_at)
      add_column :purchase_orders, :quickbooks_synced_at, :datetime
    end
    add_index :purchase_orders, :quickbooks_id, where: 'quickbooks_id IS NOT NULL', if_not_exists: true

    # Partial-unique so multiple companies can be "not connected" (NULL) but
    # any two connections must land on different QB realms.
    remove_index :companies, :quickbooks_realm_id, if_exists: true
    resolve_duplicate_realm_ids!
    add_index :companies, :quickbooks_realm_id,
              unique: true,
              where: 'quickbooks_realm_id IS NOT NULL',
              name: 'idx_companies_unique_qb_realm',
              if_not_exists: true
  end

  def down
    remove_index :companies, name: 'idx_companies_unique_qb_realm', if_exists: true

    remove_index :purchase_orders, :quickbooks_id, if_exists: true
    remove_column :purchase_orders, :quickbooks_synced_at, if_exists: true
    remove_column :purchase_orders, :quickbooks_id, if_exists: true

    remove_index :vendors, :quickbooks_id, if_exists: true
    remove_column :vendors, :quickbooks_synced_at, if_exists: true
    remove_column :vendors, :quickbooks_id, if_exists: true
  end

  private

  # For each realm_id that appears on more than one company, keep the row with
  # the most recent updated_at (assumed to be the live connection) and null the
  # rest. Logs what changed so the audit trail lives with the deploy.
  def resolve_duplicate_realm_ids!
    losers = execute(<<~SQL).to_a
      WITH ranked AS (
        SELECT
          id,
          name,
          quickbooks_realm_id,
          updated_at,
          ROW_NUMBER() OVER (
            PARTITION BY quickbooks_realm_id
            ORDER BY updated_at DESC, id DESC
          ) AS rn
        FROM companies
        WHERE quickbooks_realm_id IS NOT NULL
      )
      SELECT id, name, quickbooks_realm_id FROM ranked WHERE rn > 1
    SQL

    return if losers.empty?

    losers.each do |row|
      say "  Nulling quickbooks_realm_id on company #{row['id']} (#{row['name']}) — dup of realm #{row['quickbooks_realm_id']}"
    end

    execute(<<~SQL)
      UPDATE companies SET quickbooks_realm_id = NULL
      WHERE id IN (
        SELECT id FROM (
          SELECT
            id,
            ROW_NUMBER() OVER (
              PARTITION BY quickbooks_realm_id
              ORDER BY updated_at DESC, id DESC
            ) AS rn
          FROM companies
          WHERE quickbooks_realm_id IS NOT NULL
        ) t
        WHERE rn > 1
      )
    SQL
  end
end
