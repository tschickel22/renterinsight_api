# frozen_string_literal: true

class CreateLocations < ActiveRecord::Migration[8.0]
  def up
    # Idempotent: only create if not exists
    return if table_exists?(:locations)

    create_table :locations do |t|
      # Core identification
      t.bigint :company_id, null: false
      t.string :name, null: false
      t.string :code, limit: 10
      t.text :description
      
      # Contact information
      t.string :phone
      t.string :email
      t.string :address_line1
      t.string :address_line2
      t.string :city
      t.string :state
      t.string :zip_code
      t.string :country, default: 'US'
      
      # Operational settings
      t.string :timezone, default: 'America/New_York'
      t.jsonb :business_hours, default: {}
      t.decimal :delivery_radius_miles, precision: 10, scale: 2
      
      # Override settings (JSONB for flexibility)
      # Each location can override company-level settings
      t.jsonb :branding_settings, default: {}
      t.jsonb :communication_settings, default: {}
      t.jsonb :operational_settings, default: {}
      t.jsonb :integration_settings, default: {} # QuickBooks, Stripe, etc.
      
      # Status and metadata
      t.boolean :active, default: true, null: false
      t.boolean :is_deleted, default: false, null: false
      t.datetime :deleted_at
      
      # Audit fields
      t.string :created_by
      t.string :updated_by
      t.timestamps
    end

    # Indexes for performance
    add_index :locations, :company_id
    add_index :locations, [:company_id, :active]
    add_index :locations, [:company_id, :is_deleted]
    add_index :locations, [:company_id, :code], unique: true, where: "code IS NOT NULL"
    add_index :locations, :active
    add_index :locations, :deleted_at

    # Foreign key constraint
    add_foreign_key :locations, :companies, column: :company_id
  end

  def down
    drop_table :locations if table_exists?(:locations)
  end
end
