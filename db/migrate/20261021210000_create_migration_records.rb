# frozen_string_literal: true

# Crosswalk from another system's record ids to ours, written by data
# migrations (first: GoHighLevel, backlog E84). Every record a migration creates
# gets a row, so a second load updates instead of duplicating, children find
# their parents by the source id, and a batch can be listed or rolled back.
# loaded_at is compared with the record's updated_at on a refresh, so something
# a dealer edited in DealerTide after the first load is not overwritten.
#
# Additive only.
class CreateMigrationRecords < ActiveRecord::Migration[8.0]
  def change
    create_table :migration_records do |t|
      t.references :company, null: false, index: false
      t.string :source_system, null: false
      t.string :source_type, null: false
      t.string :source_id, null: false
      t.string :record_type, null: false
      t.bigint :record_id, null: false
      t.string :batch
      t.datetime :loaded_at, null: false
      t.timestamps
    end
    add_index :migration_records, [:company_id, :source_system, :source_type, :source_id],
              unique: true, name: 'idx_migration_records_source'
    add_index :migration_records, [:record_type, :record_id]
    add_index :migration_records, [:company_id, :batch]
  end
end
