# frozen_string_literal: true

# Quinn AI books visits (E96 phase 2): each rep's working hours, times they
# blocked, and the two calendar feeds (out: a private link that puts their
# DealerTide appointments in Google, Outlook or iPhone; in: their calendar's
# private address, read for busy times only). Additive only.
class CreateRepAvailability < ActiveRecord::Migration[8.0]
  disable_ddl_transaction!

  def change
    # { "monday" => { "open" => "09:00", "close" => "17:00", "closed" => false }, ... }
    # nil: the rep works their location's hours.
    add_column :users, :working_hours, :jsonb
    add_column :users, :calendar_feed_token, :string
    add_column :users, :busy_feed_url, :text
    add_column :users, :busy_feed_checked_at, :datetime
    add_column :users, :busy_feed_error, :string
    add_index :users, :calendar_feed_token, unique: true, where: 'calendar_feed_token IS NOT NULL', algorithm: :concurrently

    create_table :calendar_busy_blocks do |t|
      t.bigint :company_id, null: false
      t.bigint :user_id, null: false
      t.datetime :starts_at, null: false
      t.datetime :ends_at, null: false
      t.string :source, null: false, default: 'manual' # manual or feed
      t.string :note
      t.timestamps
    end
    add_index :calendar_busy_blocks, %i[user_id starts_at]
    add_index :calendar_busy_blocks, :company_id
  end
end
