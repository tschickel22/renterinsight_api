# frozen_string_literal: true

# Proactive Outreach waves, the people in them and what happened (backlog E105).
# New tables only, so old and new code can run side by side during a release.
class CreateOutreachWaves < ActiveRecord::Migration[8.0]
  def change
    create_table :outreach_waves do |t|
      t.bigint :company_id, null: false
      t.string :name, null: false
      t.string :status, null: false, default: 'building'
      t.text :prompt
      t.jsonb :filter_tree, null: false, default: {}
      t.integer :target_size, null: false, default: 25
      t.integer :daily_limit, null: false, default: 10
      t.integer :eligible_count
      t.string :pause_reason
      t.string :build_error
      t.bigint :created_by_user_id
      t.datetime :started_at
      t.datetime :paused_at
      t.datetime :completed_at
      t.timestamps
    end
    add_index :outreach_waves, %i[company_id status]
    add_foreign_key :outreach_waves, :companies

    create_table :outreach_targets do |t|
      t.bigint :company_id, null: false
      t.bigint :outreach_wave_id, null: false
      t.bigint :lead_id, null: false
      t.string :test_group, null: false, default: 'contact'
      t.string :status, null: false, default: 'selected'
      t.integer :rank
      t.string :ai_reason
      t.string :channel
      t.string :draft_subject
      t.text :draft_body
      t.bigint :draft_content_item_id
      t.string :draft_error
      t.bigint :approved_by_user_id
      t.datetime :approved_at
      t.bigint :conversation_id
      t.bigint :activity_id
      t.integer :touch_count, null: false, default: 0
      t.string :last_channel
      t.datetime :first_sent_at
      t.datetime :last_sent_at
      t.datetime :next_touch_at
      t.datetime :first_reply_at
      t.datetime :first_click_at
      t.datetime :booked_at
      t.datetime :held_at
      t.string :stop_reason
      t.timestamps
    end
    add_index :outreach_targets, %i[outreach_wave_id lead_id], unique: true
    add_index :outreach_targets, %i[company_id lead_id]
    add_index :outreach_targets, :conversation_id
    add_index :outreach_targets, %i[outreach_wave_id status next_touch_at], name: 'idx_outreach_targets_due'
    add_foreign_key :outreach_targets, :outreach_waves, column: :outreach_wave_id
    add_foreign_key :outreach_targets, :companies

    create_table :outreach_events do |t|
      t.bigint :company_id, null: false
      t.bigint :outreach_wave_id, null: false
      t.bigint :outreach_target_id, null: false
      t.string :event_type, null: false
      t.string :channel
      t.bigint :communication_id
      t.datetime :occurred_at, null: false
      t.jsonb :metadata, null: false, default: {}
      t.timestamps
    end
    add_index :outreach_events, %i[outreach_wave_id occurred_at]
    add_index :outreach_events, %i[outreach_target_id event_type]
    add_index :outreach_events, %i[outreach_target_id event_type communication_id], unique: true, name: 'idx_outreach_events_once'
    add_foreign_key :outreach_events, :outreach_targets
    add_foreign_key :outreach_events, :outreach_waves, column: :outreach_wave_id
  end
end
