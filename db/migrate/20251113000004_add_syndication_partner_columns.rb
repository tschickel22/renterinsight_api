class AddSyndicationPartnerColumns < ActiveRecord::Migration[8.0]
  def change
    add_column :syndication_partners, :api_key, :string
    add_column :syndication_partners, :webhook_url, :string
    add_column :syndication_partners, :feed_token, :string
    add_column :syndication_partners, :sync_status, :string
    add_column :syndication_partners, :sync_error, :text
    
    # Rename last_sync_at to last_synced_at for consistency
    rename_column :syndication_partners, :last_sync_at, :last_synced_at
    
    # Add index on feed_token
    add_index :syndication_partners, :feed_token, unique: true
  end
end
