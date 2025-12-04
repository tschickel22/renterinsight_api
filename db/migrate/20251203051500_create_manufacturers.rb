# frozen_string_literal: true

class CreateManufacturers < ActiveRecord::Migration[8.0]
  def change
    create_table :manufacturers do |t|
      # Basic Info
      t.string :name, null: false
      t.string :industry_type, null: false # 'rv', 'manufactured_home', 'both'
      
      # Contact Information
      t.string :contact_email
      t.string :contact_phone
      t.string :website
      
      # OEM Codes / IDs (some manufacturers require dealer codes)
      t.jsonb :oem_codes, default: {}
      
      # Warranty Portal Info (for future phase 2)
      t.boolean :has_portal_access, default: false, null: false
      t.string :portal_url
      
      # Status
      t.boolean :active, default: true, null: false
      
      # Metadata
      t.text :notes
      t.jsonb :metadata, default: {}
      
      t.timestamps
    end
    
    # Indexes
    add_index :manufacturers, :name
    add_index :manufacturers, :industry_type
    add_index :manufacturers, :active
    add_index :manufacturers, [:active, :industry_type]
    
    # Seed common manufacturers
    reversible do |dir|
      dir.up do
        # RV Manufacturers
        [
          { name: 'Forest River', industry_type: 'rv' },
          { name: 'Thor Industries', industry_type: 'rv' },
          { name: 'Grand Design', industry_type: 'rv' },
          { name: 'Jayco', industry_type: 'rv' },
          { name: 'Winnebago', industry_type: 'rv' },
          { name: 'Keystone', industry_type: 'rv' },
          { name: 'Heartland RV', industry_type: 'rv' },
          { name: 'Coachmen', industry_type: 'rv' },
          { name: 'Dutchmen', industry_type: 'rv' },
          { name: 'KZ RV', industry_type: 'rv' },
          
          # Manufactured Home Manufacturers
          { name: 'Clayton Homes', industry_type: 'manufactured_home' },
          { name: 'Champion Homes', industry_type: 'manufactured_home' },
          { name: 'Skyline Homes', industry_type: 'manufactured_home' },
          { name: 'Fleetwood', industry_type: 'manufactured_home' },
          { name: 'Cavco Industries', industry_type: 'manufactured_home' },
          { name: 'Palm Harbor Homes', industry_type: 'manufactured_home' },
          { name: 'Legacy Housing', industry_type: 'manufactured_home' },
          { name: 'Redman Homes', industry_type: 'manufactured_home' },
          { name: 'Schult Homes', industry_type: 'manufactured_home' },
          { name: 'Southern Energy Homes', industry_type: 'manufactured_home' }
        ].each do |manufacturer_data|
          execute <<-SQL
            INSERT INTO manufacturers (name, industry_type, active, created_at, updated_at)
            VALUES ('#{manufacturer_data[:name]}', '#{manufacturer_data[:industry_type]}', true, NOW(), NOW())
            ON CONFLICT DO NOTHING;
          SQL
        end
      end
    end
  end
end
