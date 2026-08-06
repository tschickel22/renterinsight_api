# frozen_string_literal: true

# Landing page support on website_pages, plus three columns that were already
# being written to and silently were not there.
#
# `robots` / `canonical_path` / `parent_page_id` are permitted by
# WebsitePagesController#page_params, declared on the frontend WebsitePage type,
# and copied by SiteEditor's page clone — but none of them existed. Rails raises
# on unknown attributes rather than ignoring them, so per-page SEO controls
# could not work. The controller even carries the comment "Will be ignored if
# column doesn't exist" and the index action has its parent lookup commented out
# for the same reason. Adding them here fixes that alongside the new work,
# because the landing page noindex default depends on `robots` existing.
class AddLandingPageColumnsToWebsitePages < ActiveRecord::Migration[8.0]
  def change
    # --- landing pages ---------------------------------------------------
    add_column :website_pages, :page_kind, :string, default: 'page', null: false
    add_index :website_pages, :page_kind

    # Nullable on purpose: a landing page built from the standalone surface has
    # no campaign. Only pages generated through Campaign Desk carry one.
    add_reference :website_pages, :campaign, null: true, foreign_key: true, index: true

    # A landing page is publishable independently of its site. The site-level
    # status stays 'published' for the system marketing container (which the
    # user never sees), so page-level state is what actually gates visibility.
    add_column :website_pages, :published_at, :datetime

    # --- pre-existing gap ------------------------------------------------
    add_column :website_pages, :robots, :string
    add_column :website_pages, :canonical_path, :string
    add_reference :website_pages, :parent_page,
                  null: true,
                  index: true,
                  foreign_key: { to_table: :website_pages }
  end
end
