# frozen_string_literal: true

# When a user was last doing something in the app.
#
# Nothing recorded this. login_activities records logins, which says someone
# arrived rather than that they are here; device_sessions.last_used_at moves
# only when a refresh token is exchanged. So the platform had no way to answer
# "who is working in the product right now", which is the other half of the
# visitor live view and the more useful half for support.
#
# Written at most once a minute per user, so this is a cheap column rather than
# a per-request write.
class AddLastActiveToUsers < ActiveRecord::Migration[8.0]
  def change
    add_column :users, :last_active_at, :datetime
    # Where they were when they were last seen. Answers the question support
    # actually has: someone stuck on one screen before they raise a ticket.
    add_column :users, :last_active_path, :string, limit: 255

    add_index :users, :last_active_at
  end
end
