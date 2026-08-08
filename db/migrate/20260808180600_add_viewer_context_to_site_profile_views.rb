class AddViewerContextToSiteProfileViews < ActiveRecord::Migration[8.0]
  # Enough to tell one viewer from another without identifying anybody.
  #
  # The need is practical: a rep looking at a demo's activity has to be able to
  # spot their own testing and tell whether the rest is one prospect or a team.
  # ip_hash groups sessions by network but says nothing a human can read.
  #
  # Timezone rather than IP geolocation. The browser reports it directly, so
  # there is no lookup, no third party, no latency on the beacon and no raw
  # address stored. It is also more useful for the actual question: a rep in
  # Denver sees America/Denver against their own sessions and America/Chicago
  # against an East Texas prospect. Coarser than a city and, for telling people
  # apart, better.
  def change
    add_column :site_profile_views, :timezone, :string
    add_column :site_profile_views, :locale, :string
  end
end
