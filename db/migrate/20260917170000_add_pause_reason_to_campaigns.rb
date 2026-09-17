# frozen_string_literal: true

# Why a campaign is paused, when the system paused it rather than a person.
#
# A campaign whose sender stopped working used to fail every enrollment one by
# one, each with the same reason, and then mark itself completed once nobody
# was left. Campaign 26 lost 586 recipients that way in September 2026. It now
# pauses with the reason recorded here, so the campaign page can say what to fix
# and resume can check it has been fixed. Null for a campaign paused by a person.
class AddPauseReasonToCampaigns < ActiveRecord::Migration[8.0]
  def change
    add_column :campaigns, :pause_reason, :jsonb
    add_column :campaigns, :paused_at, :datetime
  end
end
