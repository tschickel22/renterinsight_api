# frozen_string_literal: true

# A rep's own calendar on their DealerTide calendar (E96 follow-up). The rep
# chooses how much of each event shows, because managers and admins can open
# their calendar: nothing (busy times only feed Quinn AI, as before), busy,
# titles, or titles and places. Only what the rep chose is ever stored.
# Additive only.
class AddDetailsToCalendarFeed < ActiveRecord::Migration[8.0]
  def change
    add_column :users, :busy_feed_detail, :string, null: false, default: 'none'
    add_column :calendar_busy_blocks, :title, :string
    add_column :calendar_busy_blocks, :place, :string
    add_column :calendar_busy_blocks, :all_day, :boolean, null: false, default: false
  end
end
