# frozen_string_literal: true

class CreateLandParcels < ActiveRecord::Migration[8.0]
  def change
    create_table :land_parcels do |t|
      t.references :company, foreign_key: true, null: false
      
      # Identification
      t.string :parcel_number, null: false
      t.string :name
      
      # Location
      t.string :address
      t.string :city
      t.string :state
      t.string :zip
      t.string :county
      t.decimal :latitude, precision: 10, scale: 8
      t.decimal :longitude, precision: 11, scale: 8
      
      # Parcel Details
      t.decimal :acreage, precision: 10, scale: 4
      t.string :zoning_type # residential, commercial, agricultural, industrial, mixed_use
      t.string :status, default: 'available', null: false # available, pending, sold, under_contract, withdrawn
      
      # Pricing
      t.decimal :price, precision: 15, scale: 2
      t.decimal :price_per_acre, precision: 15, scale: 2
      
      # Utilities (stored as JSON)
      t.json :utilities, default: {} # {water: true, sewer: true, electric: true, gas: true}
      
      # Features (stored as JSON array)
      t.json :features, default: [] # ['cleared', 'wooded', 'waterfront', 'views', 'road_access']
      
      # Ownership
      t.string :owner_name
      t.string :owner_phone
      t.string :owner_email
      t.date :acquisition_date
      
      # Additional Info
      t.text :description
      t.text :notes
      
      # Media
      t.json :images, default: []
      t.json :documents, default: []
      
      # Soft Delete
      t.boolean :is_deleted, default: false, null: false
      t.datetime :deleted_at
      
      # Audit Fields
      t.integer :created_by
      t.integer :updated_by
      
      t.timestamps
    end
    
    # Indexes
    add_index :land_parcels, [:company_id, :parcel_number], unique: true
    add_index :land_parcels, :status
    add_index :land_parcels, :zoning_type
    add_index :land_parcels, :is_deleted
    add_index :land_parcels, [:city, :state]
    add_index :land_parcels, :acquisition_date
  end
end
