# frozen_string_literal: true

# Whether posts this schedule writes also get a blog version.
# nil follows the company's default (social_blog.default_on).
class AddBlogVersionToSocialPostSchedules < ActiveRecord::Migration[8.0]
  def change
    add_column :social_post_schedules, :blog_version, :boolean
  end
end
