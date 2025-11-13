# frozen_string_literal: true

class AddMitsFieldsToListings < ActiveRecord::Migration[7.1]
  def change
    # MITS Property-level fields
    add_column :listings, :property_name, :string
    add_column :listings, :office_hours, :jsonb, default: {}
    add_column :listings, :parking_details, :jsonb, default: {}
    add_column :listings, :pet_policy, :jsonb, default: {}
    add_column :listings, :concessions, :text
    add_column :listings, :promotional_text, :text
    
    # Rental-specific fields
    add_column :listings, :security_deposit, :decimal, precision: 10, scale: 2
    add_column :listings, :application_fee, :decimal, precision: 10, scale: 2
    add_column :listings, :admin_fee, :decimal, precision: 10, scale: 2
    add_column :listings, :lease_terms, :string
    add_column :listings, :available_date, :date
    add_column :listings, :effective_rent, :decimal, precision: 10, scale: 2
    
    # Property amenities (MITS format)
    add_column :listings, :property_amenities, :jsonb, default: []
    add_column :listings, :unit_amenities, :jsonb, default: []
    
    # Location coordinates (for MITS)
    add_column :listings, :latitude, :decimal, precision: 10, scale: 6
    add_column :listings, :longitude, :decimal, precision: 10, scale: 6
    
    # Unit identifier (for MITS multi-unit properties)
    add_column :listings, :unit_number, :string
    add_column :listings, :floor_plan_name, :string
    
    # Add index for unit lookups
    add_index :listings, :unit_number
    add_index :listings, [:company_id, :property_name]
  end
end
