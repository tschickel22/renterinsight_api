# frozen_string_literal: true

# Platform-side monitoring of a single user's request trail.
#
# Render keeps request logs about 7 days, so answering "what has this user been
# doing" after the fact was a race against retention. A watch captures the trail
# into durable storage for as long as it is active.
class CreateUserActivityWatches < ActiveRecord::Migration[8.0]
  def change
    create_table :user_activity_watches do |t|
      t.bigint  :user_id,            null: false
      t.bigint  :company_id,         null: false
      t.bigint  :created_by_user_id, null: false
      t.text    :reason,             null: false
      t.boolean :active,             null: false, default: true
      t.datetime :started_at,        null: false
      t.datetime :ended_at
      t.timestamps
    end

    add_index :user_activity_watches, %i[user_id active]
    add_index :user_activity_watches, :company_id

    create_table :watched_requests do |t|
      t.bigint  :user_activity_watch_id, null: false
      t.bigint  :user_id,                null: false
      t.bigint  :company_id,             null: false
      t.string  :http_method,            null: false
      t.string  :path,                   null: false, limit: 2048
      t.string  :controller_action
      t.integer :status
      t.integer :duration_ms
      t.string  :ip_address
      t.string  :user_agent,             limit: 512
      # Background polling is recorded but flagged, so the census can exclude it
      # while the raw trail stays complete for evidence.
      t.boolean :is_poll,                null: false, default: false
      t.datetime :occurred_at,           null: false
    end

    add_index :watched_requests, %i[user_activity_watch_id occurred_at],
              name: 'index_watched_requests_on_watch_and_time'
    add_index :watched_requests, %i[user_id occurred_at]
  end
end
