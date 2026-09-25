# frozen_string_literal: true

# The blog version's category, chosen by the author (or suggested from the
# site's own categories) instead of every post landing in "General".
class AddCategoryToSocialPostCrossPosts < ActiveRecord::Migration[8.0]
  def change
    add_column :social_post_cross_posts, :category, :string
  end
end
