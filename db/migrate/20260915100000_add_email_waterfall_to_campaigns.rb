# frozen_string_literal: true

# A campaign with email_waterfall on never skips a recipient for want of a
# mailbox: with no rep (or owner) mailbox it sends the way every other email
# does, from the recipient's location settings, then the company's, then the
# platform's. Off by default, so existing campaigns keep sending only through a
# connected mailbox.
class AddEmailWaterfallToCampaigns < ActiveRecord::Migration[8.0]
  def up
    add_column :campaigns, :email_waterfall, :boolean, default: false, null: false

    # Campaigns the starter plays already built are the ones this is for.
    execute <<~SQL.squish
      UPDATE campaigns SET email_waterfall = TRUE
      WHERE utm_campaign IN ('weekly_homes_email', 'wake_up_cold_leads')
    SQL
  end

  def down
    remove_column :campaigns, :email_waterfall
  end
end
