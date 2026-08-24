# frozen_string_literal: true

# Per-page analytics and pixels.
#
# tracking_config already exists on websites, but a landing page cannot use it.
# Landing pages live on the system-owned marketing container, which is hidden
# from the websites list precisely so nobody edits it, so there has never been a
# surface for setting a pixel on a campaign page. That is the one kind of page
# most likely to need its own: a Facebook ad wants its own pixel and conversion
# event, and pointing every campaign at one shared site-wide pixel makes the
# numbers useless.
#
# Merged over the website's rather than replacing it, so a dealer keeps one
# site-wide GTM container and adds a per-campaign pixel on top.
class AddTrackingConfigToWebsitePages < ActiveRecord::Migration[8.0]
  def change
    add_column :website_pages, :tracking_config, :jsonb, default: {}, null: false
  end
end
