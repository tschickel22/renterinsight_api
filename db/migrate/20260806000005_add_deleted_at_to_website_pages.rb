# frozen_string_literal: true

# website_pages tracks soft deletion with is_deleted but never recorded WHEN.
#
# websites, blog_posts, website_media and blog_categories all carry deleted_at,
# and the frontend WebsitePage type declares it, so its absence here is an
# oversight rather than a decision. Without it a soft-deleted page cannot be
# aged out or explained — "deleted, at some point" is not enough to build a
# retention policy on.
class AddDeletedAtToWebsitePages < ActiveRecord::Migration[8.0]
  def change
    add_column :website_pages, :deleted_at, :datetime
  end
end
