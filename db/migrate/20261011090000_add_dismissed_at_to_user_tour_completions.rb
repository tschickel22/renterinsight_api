# frozen_string_literal: true

# A skipped or declined tour used to be recorded as completed, which hid it
# from the user's tour list and counted as a completion in analytics. It now
# gets its own timestamp: it stops prompting, but stays available to retake.
class AddDismissedAtToUserTourCompletions < ActiveRecord::Migration[8.0]
  def change
    add_column :user_tour_completions, :dismissed_at, :datetime
  end
end
