class CreateWebsiteMedia < ActiveRecord::Migration[8.0]
  def change
    create_table :website_media do |t|
      # Multi-tenancy
      t.references :company, null: false, foreign_key: true
      t.references :website, null: true, foreign_key: { to_table: :websites }
      t.references :uploaded_by, null: true, foreign_key: { to_table: :users }
      
      # File details
      t.string :name, null: false
      t.string :url, null: false
      t.string :file_type, null: false
      t.string :mime_type
      t.bigint :file_size, null: false
      
      # Image dimensions (if applicable)
      t.integer :width
      t.integer :height
      
      # S3 details
      t.string :s3_key
      t.string :s3_bucket
      
      # Soft delete
      t.boolean :is_deleted, default: false
      
      t.timestamps
    end
    
    # Note: indexes on company_id, website_id, uploaded_by_id automatically created by t.references above
    add_index :website_media, :file_type
  end
end
