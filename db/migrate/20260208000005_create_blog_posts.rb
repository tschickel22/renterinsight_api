class CreateBlogPosts < ActiveRecord::Migration[8.0]
  def change
    create_table :blog_posts do |t|
      t.references :website, null: false, foreign_key: { to_table: :websites }
      t.references :author, null: false, foreign_key: { to_table: :users }
      
      # Post details
      t.string :title, null: false
      t.string :slug, null: false
      t.text :excerpt
      t.text :content
      
      # Featured image
      t.string :featured_image_url
      
      # Status
      t.integer :status, default: 0, null: false
      
      # Publishing
      t.datetime :published_at
      t.datetime :scheduled_at
      
      # SEO
      t.string :seo_title
      t.text :seo_description
      t.string :og_image_url
      
      # Analytics
      t.integer :view_count, default: 0
      
      # Soft delete
      t.boolean :is_deleted, default: false
      
      t.timestamps
    end
    
    add_index :blog_posts, [:website_id, :slug], unique: true
    add_index :blog_posts, :status
    add_index :blog_posts, :published_at
  end
end
