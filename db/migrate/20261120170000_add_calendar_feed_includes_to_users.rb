# frozen_string_literal: true

# E108: what a person's private calendar link carries. meetings is what it
# always carried; meetings_and_projects adds the project phases and tasks
# that are theirs. Additive only.
class AddCalendarFeedIncludesToUsers < ActiveRecord::Migration[8.0]
  def change
    add_column :users, :calendar_feed_includes, :string, null: false, default: 'meetings'
  end
end
