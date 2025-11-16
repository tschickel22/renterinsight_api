# frozen_string_literal: true

class CreateUserLocations < ActiveRecord::Migration[8.0]
  def up
    # Idempotent: only create if not exists
    return if table_exists?(:user_locations)

    create_table :user_locations do |t|
      # Associations
      t.bigint :user_id, null: false
      t.bigint :location_id, null: false
      t.bigint :company_id, null: false # Denormalized for fast queries
      
      # Role at this specific location
      # Options: 'location_admin', 'location_manager', 'location_staff'
      # Company admins don't need entries here (they have access to all locations)
      t.string :location_role, default: 'location_staff'
      
      # Status
      t.boolean :active, default: true, null: false
      
      # Audit fields
      t.string :assigned_by
      t.timestamps
    end

    # Indexes for performance
    add_index :user_locations, [:user_id, :location_id], unique: true
    add_index :user_locations, :user_id
    add_index :user_locations, :location_id
    add_index :user_locations, :company_id
    add_index :user_locations, [:company_id, :location_id]
    add_index :user_locations, :active

    # Foreign key constraints
    add_foreign_key :user_locations, :users, column: :user_id
    add_foreign_key :user_locations, :locations, column: :location_id
    add_foreign_key :user_locations, :companies, column: :company_id
  end

  def down
    drop_table :user_locations if table_exists?(:user_locations)
  end
end
