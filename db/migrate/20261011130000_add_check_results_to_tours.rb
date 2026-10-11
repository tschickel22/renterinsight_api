# frozen_string_literal: true

# Tour health (backlog E75, phase 5): the last time each step was checked
# against the live app and whether its element was there. A tour whose step
# went missing is flagged in Knowledge admin before a customer finds it.
class AddCheckResultsToTours < ActiveRecord::Migration[8.0]
  def change
    add_column :tour_steps, :check_status, :string # found | missing | ambiguous
    add_column :tour_steps, :checked_at, :datetime
    add_column :tours, :checked_at, :datetime
    add_column :tours, :check_status, :string # passing | failing
  end
end
