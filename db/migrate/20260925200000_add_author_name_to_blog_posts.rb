# frozen_string_literal: true

# A byline that is not a user account: "Admin", the company, or a name typed
# in. blog_posts.author_id stays required (it is who created the post); this
# is what readers see when set. The blog version carries it until it publishes.
class AddAuthorNameToBlogPosts < ActiveRecord::Migration[8.0]
  def change
    add_column :blog_posts, :author_name, :string
    add_column :social_post_cross_posts, :author_name, :string
  end
end
