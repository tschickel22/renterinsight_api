# frozen_string_literal: true

# Conversion-tracking settings for public intake forms.
#
# `tracking_settings` holds ad-platform IDs (Meta Pixel, Google GA4/Ads) used to
# fire PageView + Lead conversions on public forms. Company holds the default;
# a location's blob overrides the company per-key (blank/absent => inherit).
# Stored as a pass-through blob keyed camelCase to match the frontend helper
# (metaPixelId, googleGa4Id, googleAdsId, googleAdsLeadLabel).
class AddTrackingSettingsToCompaniesAndLocations < ActiveRecord::Migration[8.0]
  def change
    add_column :companies, :tracking_settings, :jsonb, default: {}, null: false
    add_column :locations, :tracking_settings, :jsonb, default: {}, null: false
  end
end
