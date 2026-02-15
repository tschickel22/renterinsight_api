class AddMissingBlogColumns < ActiveRecord::Migration[8.0]
  def change
    # Blog categories - missing order and deleted_at
    unless column_exists?(:blog_categories, :order)
      add_column :blog_categories, :order, :integer, default: 0
    end
    unless column_exists?(:blog_categories, :deleted_at)
      add_column :blog_categories, :deleted_at, :datetime
    end
    unless column_exists?(:blog_categories, :seo_title)
      add_column :blog_categories, :seo_title, :string
    end
    unless column_exists?(:blog_categories, :seo_description)
      add_column :blog_categories, :seo_description, :text
    end

    # Blog posts - missing featured_image_alt, robots, deleted_at
    unless column_exists?(:blog_posts, :featured_image_alt)
      add_column :blog_posts, :featured_image_alt, :string
    end
    unless column_exists?(:blog_posts, :robots)
      add_column :blog_posts, :robots, :string
    end
    unless column_exists?(:blog_posts, :deleted_at)
      add_column :blog_posts, :deleted_at, :datetime
    end
  end
end
