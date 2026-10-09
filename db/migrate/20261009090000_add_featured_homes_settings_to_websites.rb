class AddFeaturedHomesSettingsToWebsites < ActiveRecord::Migration[8.0]
  # How a site shows its picked Featured Homes: how many at a time, and
  # whether (and how often) the shown set rotates through the picks.
  def change
    add_column :websites, :featured_homes_settings, :jsonb, default: {}, null: false
  end
end
