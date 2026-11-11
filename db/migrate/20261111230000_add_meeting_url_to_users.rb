# frozen_string_literal: true

# A person's own video meeting link (Zoom, Teams, Google Meet), on their
# profile. Quinn puts it on a video visit or demo it books with them.
class AddMeetingUrlToUsers < ActiveRecord::Migration[8.0]
  def change
    add_column :users, :meeting_url, :string
  end
end
