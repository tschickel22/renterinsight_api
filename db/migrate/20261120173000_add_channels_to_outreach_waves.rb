# frozen_string_literal: true

# Which channels a Proactive Outreach wave uses and which one opens (backlog E105).
class AddChannelsToOutreachWaves < ActiveRecord::Migration[8.0]
  def change
    add_column :outreach_waves, :channels, :string, null: false, default: 'both'
    add_column :outreach_waves, :first_channel, :string, null: false, default: 'email'
  end
end
