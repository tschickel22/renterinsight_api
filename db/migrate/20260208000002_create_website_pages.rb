class CreateWebsitePages < ActiveRecord::Migration[8.0]
  def change
    create_table :website_pages do |t|
      t.references :website, null: false, foreign_key: { to_table: :websites }
      
      # Page details
      t.string :title, null: false
      t.string :path, null: false
      t.integer :order, default: 0
      t.boolean :is_visible, default: true
      
      # Content
      t.jsonb :blocks, default: []
      
      # SEO
      t.string :seo_title
      t.text :seo_description
      t.string :og_image_url
      
      # Soft delete
      t.boolean :is_deleted, default: false
      
      t.timestamps
    end
    
    add_index :website_pages, [:website_id, :path], unique: true
    add_index :website_pages, :order
  end
end
