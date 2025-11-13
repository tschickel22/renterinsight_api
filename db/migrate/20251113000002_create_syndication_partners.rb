# frozen_string_literal: true

class CreateSyndicationPartners < ActiveRecord::Migration[7.1]
  def change
    create_table :syndication_partners do |t|
      # Core association
      t.references :company, null: false, foreign_key: true, index: true
      
      # Partner details
      t.string :name, null: false
      t.string :partner_type, null: false
      t.string :format, null: false, default: 'json'
      
      # Configuration
      t.text :listing_types, array: true, default: []
      t.string :feed_url
      t.string :account_id
      
      # Contact information
      t.string :lead_email
      t.string :contact_name
      t.string :contact_phone
      
      # Status
      t.boolean :active, default: true
      t.datetime :last_sync_at
      
      # Additional settings
      t.jsonb :settings, default: {}
      t.jsonb :sync_metadata, default: {}
      
      t.timestamps
    end
    
    # Add indexes
    add_index :syndication_partners, :partner_type
    add_index :syndication_partners, :active
    add_index :syndication_partners, [:company_id, :active]
    add_index :syndication_partners, [:company_id, :partner_type]
  end
end
