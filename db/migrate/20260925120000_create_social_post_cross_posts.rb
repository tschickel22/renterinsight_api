# frozen_string_literal: true

# The blog version of a social post. A social post is one row per social
# network and its publish code assumes Facebook, so the blog lives beside it
# rather than as another platform value.
#
# status:
#   pending   - goes out as a blog post when the social post publishes
#   skipped   - the author unticked it, or the approver chose "Facebook only"
#   published - the blog post exists; external_id and public_url say where
#   failed    - publishing was tried and did not work; error says why
class CreateSocialPostCrossPosts < ActiveRecord::Migration[8.0]
  def change
    create_table :social_post_cross_posts do |t|
      t.references :company,     null: false, foreign_key: true
      t.references :social_post, null: false, foreign_key: true
      t.string  :destination, null: false, default: 'website_builder'
      t.bigint  :website_id
      t.string  :status, null: false, default: 'pending'

      t.string  :title
      t.string  :slug
      t.text    :content
      t.text    :excerpt
      t.string  :seo_title
      t.text    :seo_description
      t.jsonb   :tags, null: false, default: []
      t.string  :featured_image_url
      t.string  :ai_generation_version
      t.datetime :generated_at

      t.string   :external_id
      t.string   :public_url
      t.datetime :published_at
      t.text     :error

      t.timestamps
    end

    add_index :social_post_cross_posts, [:social_post_id, :destination], unique: true
    add_index :social_post_cross_posts, :status
  end
end
