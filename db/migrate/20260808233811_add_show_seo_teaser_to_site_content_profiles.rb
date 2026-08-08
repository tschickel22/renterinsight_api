# frozen_string_literal: true

# The third state for the SEO review on a shared demo.
#
# There were two: show the client report, or hide it and leave a teaser in the
# header saying how many gaps we found. That teaser assumes the findings are
# always a reason to switch, and on a site that already scores well they are the
# opposite: a banner reading "we found 2 gaps" argues the incumbent is doing
# fine. Hiding the report entirely has to be possible.
#
# Defaults to true so every existing demo keeps behaving exactly as it does now.
class AddShowSeoTeaserToSiteContentProfiles < ActiveRecord::Migration[8.0]
  def change
    add_column :site_content_profiles, :show_seo_teaser, :boolean, default: true, null: false
  end
end
