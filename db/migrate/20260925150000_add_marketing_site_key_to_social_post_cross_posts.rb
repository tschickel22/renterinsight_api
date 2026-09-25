# frozen_string_literal: true

# Which marketing site a blog version goes to when destination is
# 'marketing_site'. The site's connection details live in ENV, keyed by this;
# see SocialBlog::MarketingSites.
class AddMarketingSiteKeyToSocialPostCrossPosts < ActiveRecord::Migration[8.0]
  def change
    add_column :social_post_cross_posts, :marketing_site_key, :string
  end
end
