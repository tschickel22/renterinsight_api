class CreateBlogPostsCategories < ActiveRecord::Migration[8.0]
  def change
    create_table :blog_posts_categories, id: false do |t|
      t.references :blog_post, null: false, foreign_key: true
      t.references :blog_category, null: false, foreign_key: true
    end
    
    add_index :blog_posts_categories, [:blog_post_id, :blog_category_id], 
              unique: true, 
              name: 'index_blog_posts_categories_on_post_and_category'
  end
end
