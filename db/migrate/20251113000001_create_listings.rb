# frozen_string_literal: true

class CreateListings < ActiveRecord::Migration[7.1]
  def change
    create_table :listings do |t|
      # Core associations
      t.references :company, null: false, foreign_key: true, index: true
      t.references :vehicle, null: false, foreign_key: true, index: true
      
      # Listing status
      t.string :status, null: false, default: 'draft'
      t.string :offer_type, null: false
      
      # Pricing
      t.decimal :sale_price, precision: 12, scale: 2
      t.decimal :rent_price, precision: 10, scale: 2
      t.string :rent_period
      
      # Listing content
      t.text :description
      t.text :features
      t.jsonb :additional_features, default: {}
      
      # MH Village specific fields
      t.string :package_type
      t.string :location_type
      t.string :community_name
      t.decimal :lot_rent, precision: 10, scale: 2
      t.string :financing_available
      t.string :delivery_available
      t.string :setup_included
      
      # Feature flags (MH Village requirements)
      t.boolean :has_garage, default: false
      t.boolean :has_fireplace, default: false
      t.boolean :has_deck, default: false
      t.boolean :has_shed, default: false
      t.boolean :has_appliances, default: false
      t.boolean :has_ac, default: false
      t.boolean :is_furnished, default: false
      t.boolean :pets_allowed, default: false
      
      # Seller/Agent information
      t.string :seller_name
      t.string :seller_phone
      t.string :seller_email
      t.string :agent_name
      t.string :agent_phone
      t.string :agent_email
      
      # Syndication tracking
      t.datetime :published_at
      t.datetime :last_synced_at
      t.jsonb :syndication_metadata, default: {}
      
      # Soft delete
      t.boolean :is_deleted, default: false
      t.datetime :deleted_at
      
      t.timestamps
    end
    
    # Add indexes for common queries
    add_index :listings, :status
    add_index :listings, :offer_type
    add_index :listings, :published_at
    add_index :listings, [:company_id, :status]
    add_index :listings, [:company_id, :is_deleted]
  end
end
