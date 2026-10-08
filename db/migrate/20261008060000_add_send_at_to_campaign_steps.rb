# frozen_string_literal: true

# A step can send on a date and time instead of after a wait, for messages
# tied to a calendar day (the day of an event). send_at_timezone is the zone
# the dealer picked the time in, so "the day of the event" means their day.
class AddSendAtToCampaignSteps < ActiveRecord::Migration[8.0]
  def change
    add_column :campaign_steps, :send_at, :datetime
    add_column :campaign_steps, :send_at_timezone, :string
  end
end
