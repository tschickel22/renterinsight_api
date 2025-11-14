# frozen_string_literal: true

class AddRentalFieldsToListings < ActiveRecord::Migration[8.0]
  def change
    # Deposit fields
    add_column :listings, :pet_deposit, :decimal, precision: 10, scale: 2
    add_column :listings, :key_deposit, :decimal, precision: 10, scale: 2
    add_column :listings, :other_deposit, :decimal, precision: 10, scale: 2
    add_column :listings, :other_deposit_description, :string
    
    # Monthly fee fields
    add_column :listings, :pet_rent, :decimal, precision: 10, scale: 2
    add_column :listings, :parking_fee, :decimal, precision: 10, scale: 2
    add_column :listings, :storage_fee, :decimal, precision: 10, scale: 2
    add_column :listings, :trash_fee, :decimal, precision: 10, scale: 2
    add_column :listings, :utilities_included, :jsonb, default: {}
    
    # Lease term fields
    add_column :listings, :min_lease_term, :integer
    add_column :listings, :max_lease_term, :integer
    add_column :listings, :lease_type, :string
    
    # Unit details
    add_column :listings, :floor_number, :integer
    add_column :listings, :unit_type, :string
    
    # Availability/specials
    add_column :listings, :specials_description, :text
    add_column :listings, :move_in_date_type, :string, default: 'specific_date'
    add_column :listings, :immediately_available, :boolean, default: false
    
    # Income requirements
    add_column :listings, :income_requirement_multiplier, :decimal, precision: 3, scale: 1
    add_column :listings, :credit_check_required, :boolean, default: true
    add_column :listings, :background_check_required, :boolean, default: true
    
    # Add indexes for commonly queried fields
    add_index :listings, :unit_type
    add_index :listings, :available_date
    add_index :listings, :immediately_available
    add_index :listings, :floor_number
  end
end
