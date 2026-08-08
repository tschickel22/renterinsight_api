class AddSeoReportToSiteContentProfiles < ActiveRecord::Migration[8.0]
  # The SEO audit of the prospect's CURRENT site, and whether the prospect is
  # allowed to see it.
  #
  # The audit always runs, so the admin can read it before deciding. The flag
  # only governs whether the shared demo shows the report to the client, which
  # is a judgement call about the conversation rather than about the data: the
  # same findings that open one dealer's eyes will insult another's nephew who
  # built the site.
  #
  # Defaults to true because the report is the reason the scan is worth showing,
  # and hiding it is the exception the admin opts into.
  def change
    add_column :site_content_profiles, :seo_report, :jsonb
    add_column :site_content_profiles, :show_seo_report, :boolean, default: true, null: false
  end
end
