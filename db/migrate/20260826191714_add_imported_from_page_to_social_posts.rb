# frozen_string_literal: true

# Comments on posts published straight to the Facebook Page were unreachable.
# social_comments.social_post_id is NOT NULL, so a comment can only be stored
# against a social_posts row, and a post made on Facebook never had one.
#
# The comment sync now adopts the Page's own recent posts so their comments
# have somewhere to hang. This flag keeps those rows out of the Posts tab,
# which counts what was created in DealerTide and should go on meaning that.
class AddImportedFromPageToSocialPosts < ActiveRecord::Migration[8.0]
  def change
    add_column :social_posts, :imported_from_page, :boolean, default: false, null: false

    # Every Posts-tab query filters on it, so it belongs beside company_id.
    add_index :social_posts, %i[company_id imported_from_page],
              name: 'index_social_posts_on_company_id_and_imported'
  end
end
