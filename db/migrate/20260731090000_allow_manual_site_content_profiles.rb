# frozen_string_literal: true

# Hand-entered demos have no site to point at: a prospect with no website still
# needs a shareable preview, and the model already guards presence for scans.
class AllowManualSiteContentProfiles < ActiveRecord::Migration[8.0]
  def change
    change_column_null :site_content_profiles, :source_url, true
  end
end
