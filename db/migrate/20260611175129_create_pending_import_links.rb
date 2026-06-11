# frozen_string_literal: true

# Stores import lookups that could not be resolved at the time a record was
# imported (e.g. a service ticket whose vehicle/deal hasn't been uploaded yet).
# A resolver back-fills the foreign key when a matching parent later appears,
# making import order-independent and allowing re-linking across separate
# upload sessions.
class CreatePendingImportLinks < ActiveRecord::Migration[8.0]
  def change
    create_table :pending_import_links do |t|
      t.references :company, null: false, foreign_key: true

      # The child record that is waiting for a parent (polymorphic).
      # e.g. entity_type='ServiceTicket', entity_id=123
      t.string  :entity_type, null: false
      t.bigint  :entity_id,   null: false

      # The foreign-key column on the child to populate once resolved.
      # e.g. 'account_id'
      t.string  :target_column, null: false

      # How to find the parent: the parent model, the columns to match against,
      # and the raw human-readable value pulled from the CSV.
      # e.g. parent_model='Account', match_fields=['name'], lookup_value='Smith Homes'
      t.string  :parent_model,  null: false
      t.jsonb   :match_fields,  null: false, default: []
      t.string  :lookup_value,  null: false

      # The lookup key from ModuleRegistry::LOOKUP_FIELDS (e.g. 'account_name'),
      # retained for diagnostics and to re-run name-aware matching identically.
      t.string  :lookup_key

      # resolution lifecycle: 'pending' -> 'resolved' (or 'abandoned' on cleanup)
      t.string   :status, null: false, default: 'pending'
      t.datetime :resolved_at
      t.bigint   :resolved_parent_id

      # The import job that created this pending link (for auditing / scoping a
      # resolution sweep to a single onboarding run if desired).
      t.references :import_job, foreign_key: true, null: true

      t.timestamps
    end

    # Primary resolution query: given a freshly-created parent of type X with a
    # value Y, find pending links whose parent_model=X and lookup_value ~ Y.
    add_index :pending_import_links, %i[company_id parent_model status],
              name: 'idx_pending_links_resolution'

    # Fast lookup of all pending links belonging to a child (used when a child
    # is destroyed, or to report unlinked records after an import).
    add_index :pending_import_links, %i[entity_type entity_id],
              name: 'idx_pending_links_entity'

    # Value-scoped sweeps.
    add_index :pending_import_links, %i[company_id status lookup_value],
              name: 'idx_pending_links_value'
  end
end
