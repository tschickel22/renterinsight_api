# frozen_string_literal: true

# Video is a different Meta endpoint (/videos, not /photos or /feed) and can't
# be mixed with photos in one post, so it gets its own column rather than
# sharing image_urls — which would leave every consumer sniffing extensions to
# tell the two apart.
class AddVideoUrlToSocialPosts < ActiveRecord::Migration[8.0]
  def change
    add_column :social_posts, :video_url, :string
  end
end
