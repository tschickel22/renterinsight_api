# frozen_string_literal: true

class AddRunDatesToAdCampaigns < ActiveRecord::Migration[8.0]
  def change
    # When the campaign actually ran, per Meta. Attribution had no time bound at
    # all, so a campaign that stopped a year ago kept claiming every new lead
    # whose utm_campaign still matched its name.
    #
    # Null on existing rows and on campaigns Meta reports no dates for; the
    # matcher falls back to unbounded rather than attributing nothing.
    add_column :ad_campaigns, :started_at, :datetime
    add_column :ad_campaigns, :stopped_at, :datetime
  end
end
