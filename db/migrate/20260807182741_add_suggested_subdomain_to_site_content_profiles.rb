class AddSuggestedSubdomainToSiteContentProfiles < ActiveRecord::Migration[8.0]
  # The address a demo would get if it were committed to a real site.
  #
  # Derived from the scanned brand name so it is right most of the time, and
  # stored rather than recomputed so a platform admin can correct it before the
  # site exists — which is the only moment they get, since after commit it
  # belongs to the dealer.
  #
  # Nullable: a profile that predates this, or one whose brand name yields
  # nothing usable, simply has no suggestion and the commit screen falls back
  # to deriving one from the site name.
  def change
    add_column :site_content_profiles, :suggested_subdomain, :string
  end
end
