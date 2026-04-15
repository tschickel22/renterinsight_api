# frozen_string_literal: true

# Feed sync history for Champion IMS.
#
# Two-table design (parent/child) so the UI can show:
#   - A reverse-chrono list of sync RUNS per retailer (the parent rows)
#   - Drill-down into the per-home EVENTS for any one run (the children)
#
# Why two tables instead of one event log:
#   - Events without a run grouping make "show me what happened in last sync"
#     a giant-OR query and lose the duration/started_at metadata
#   - A run row gives us a stable parent for cascade-delete when a retailer
#     is removed, and a single place to store run-level totals so common
#     summaries don't have to GROUP BY 50k events
class CreateChampionImsSyncHistory < ActiveRecord::Migration[8.0]
  def change
    create_table :champion_ims_sync_runs do |t|
      t.references :company,                   null: false, foreign_key: true, index: true
      t.references :champion_ims_retailer,     null: false, foreign_key: true, index: { name: 'idx_cims_runs_on_retailer' }
      t.string     :status,                    null: false, default: 'running' # running | success | failed
      t.datetime   :started_at,                null: false
      t.datetime   :finished_at
      t.integer    :duration_ms
      t.integer    :catalog_added,             null: false, default: 0
      t.integer    :catalog_updated,           null: false, default: 0
      t.integer    :catalog_unchanged,         null: false, default: 0
      t.integer    :catalog_tombstoned,        null: false, default: 0
      t.integer    :catalog_protected,         null: false, default: 0
      t.integer    :vehicles_skipped,          null: false, default: 0
      t.integer    :total,                     null: false, default: 0
      t.string     :trigger,                   null: false, default: 'manual' # manual | scheduled
      t.text       :error_message
      t.timestamps
    end

    add_index :champion_ims_sync_runs, [:champion_ims_retailer_id, :started_at],
              order: { started_at: :desc },
              name:  'idx_cims_runs_on_retailer_and_started_at'

    create_table :champion_ims_sync_events do |t|
      t.references :champion_ims_sync_run, null: false, foreign_key: true, index: { name: 'idx_cims_events_on_run' }
      t.references :vehicle,               null: true,  foreign_key: true, index: { name: 'idx_cims_events_on_vehicle' } # null for skipped (no vehicle was created)
      t.string     :champion_model_id,     null: true,  index: true # always present even for skipped rows
      t.string     :event_type,            null: false, index: true # added | updated | unchanged | tombstoned | protected | skipped
      # Snapshot of identifying display fields so events stay readable even if
      # the vehicle is later hard-deleted or its name changes
      t.string     :display_name
      t.string     :inventory_id
      # For event_type='updated': field-level diff in shape
      #   { "field_name" => { "from" => <prev>, "to" => <new> }, ... }
      t.jsonb      :changes,               default: {}, null: false
      # For skipped/protected: human-readable reason
      t.text       :reason
      t.timestamps
    end

    # Common query: "what happened to vehicle X across all runs?"
    add_index :champion_ims_sync_events, [:vehicle_id, :created_at],
              order: { created_at: :desc },
              name:  'idx_cims_events_on_vehicle_and_created_at'
  end
end
