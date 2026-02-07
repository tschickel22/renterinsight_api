class CreateWebsiteVersions < ActiveRecord::Migration[8.0]
  def change
    create_table :website_versions do |t|
      t.references :website, null: false, foreign_key: { to_table: :websites }
      t.references :created_by, null: false, foreign_key: { to_table: :users }
      
      # Version details
      t.string :version_name, null: false
      t.jsonb :snapshot, null: false
      t.boolean :is_published_version, default: false
      
      t.timestamps
    end
    
    # Note: indexes on website_id and created_by_id automatically created by t.references above
    add_index :website_versions, :created_at
  end
end
