# frozen_string_literal: true

# Revert the partial unique index added in QbBatch1SchemaFixes. In production
# QB realms are naturally unique per Intuit customer, but in dev/staging
# multiple test companies commonly point at the same sandbox realm — the
# unique constraint blocked legitimate sandbox connection flows.
#
# Prod safety is preserved by Intuit's own realm uniqueness guarantee plus
# the webhook lookup returning the first match; we can add a validator or
# app-level check later if a real conflict ever materializes.
class DropUniqueQbRealmIndex < ActiveRecord::Migration[8.0]
  def change
    remove_index :companies, name: 'idx_companies_unique_qb_realm', if_exists: true

    # Restore the plain (non-unique) index so realm-id lookups still hit an
    # index (webhook receiver reads by realm).
    add_index :companies, :quickbooks_realm_id,
              name: 'index_companies_on_quickbooks_realm_id',
              if_not_exists: true
  end
end
