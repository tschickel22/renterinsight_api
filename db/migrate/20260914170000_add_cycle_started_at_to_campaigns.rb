class AddCycleStartedAtToCampaigns < ActiveRecord::Migration[8.0]
  # When the current cycle of a recurring campaign opened. The duplicate-send
  # guard only counts sends inside the cycle, so a weekly digest can go to the
  # same person again next week.
  def change
    add_column :campaigns, :cycle_started_at, :datetime
  end
end
