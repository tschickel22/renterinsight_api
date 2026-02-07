class CreateWebsites < ActiveRecord::Migration[8.0]
  def change
    create_table :websites do |t|
      # Multi-tenancy
      t.references :company, null: false, foreign_key: true
      t.references :location, null: true, foreign_key: true
      
      # Basic info
      t.string :name, null: false
      t.string :slug, null: false
      t.string :domain
      t.string :subdomain
      
      # Status
      t.integer :status, default: 0, null: false
      t.integer :build_status, default: 0, null: false
      t.integer :client_access_level, default: 0, null: false
      
      # Content (JSONB for flexibility)
      t.jsonb :theme, default: {}
      t.jsonb :nav_config, default: {}
      t.jsonb :brand, default: {}
      t.jsonb :seo_config, default: {}
      t.jsonb :tracking_config, default: {}
      
      # Assets
      t.string :favicon_url
      
      # Publishing
      t.datetime :published_at
      t.string :preview_url
      t.string :live_url
      
      # External integrations
      t.string :netlify_site_id
      t.string :cloudflare_zone_id
      
      # Soft delete
      t.boolean :is_deleted, default: false
      
      t.timestamps
    end
    
    add_index :websites, [:company_id, :slug], unique: true
    add_index :websites, :subdomain, unique: true, where: "subdomain IS NOT NULL"
    add_index :websites, :domain, unique: true, where: "domain IS NOT NULL"
    # Note: index on location_id is automatically created by t.references above
  end
end
