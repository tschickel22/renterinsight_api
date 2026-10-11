# frozen_string_literal: true

# Which parts of the product each person uses (backlog E75, phase 3).
#
# guide_events is the raw stream (page views and clicks on data-tour markers),
# kept 90 days. guide_feature_usages is the per-person rollup that checklists,
# coaching and adoption views read; it is kept.
#
# Feature keys and routes only. No field values, no record contents.
class CreateGuideUsageTables < ActiveRecord::Migration[8.0]
  def change
    create_table :guide_events do |t|
      t.bigint   :company_id, null: false
      t.bigint   :user_id,    null: false
      t.string   :kind,        null: false # page | click
      t.string   :feature_key, null: false
      t.string   :route
      t.datetime :occurred_at, null: false
      t.datetime :created_at,  null: false
    end
    add_index :guide_events, %i[company_id occurred_at]
    add_index :guide_events, %i[user_id occurred_at]
    add_index :guide_events, :occurred_at

    create_table :guide_feature_usages do |t|
      t.bigint   :company_id,    null: false
      t.bigint   :user_id,       null: false
      t.string   :feature_key,   null: false
      t.datetime :first_used_at, null: false
      t.datetime :last_used_at,  null: false
      t.integer  :use_count,     null: false, default: 0
      t.timestamps
    end
    add_index :guide_feature_usages, %i[user_id feature_key], unique: true
    add_index :guide_feature_usages, %i[company_id feature_key]
  end
end
