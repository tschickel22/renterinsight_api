class CreateBlogCategories < ActiveRecord::Migration[8.0]
  def change
    create_table :blog_categories do |t|
      t.references :website, null: false, foreign_key: { to_table: :websites }
      
      # Category details
      t.string :name, null: false
      t.string :slug, null: false
      t.text :description
      
      # Soft delete
      t.boolean :is_deleted, default: false
      
      t.timestamps
    end
    
    add_index :blog_categories, [:website_id, :slug], unique: true
  end
end
