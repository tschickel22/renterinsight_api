# frozen_string_literal: true

class CreateLotMapTables < ActiveRecord::Migration[7.0]
  def change
    # Lot Map Layouts - Main layout/dealership information
    create_table :lot_map_layouts do |t|
      t.integer :company_id, null: false
      t.string :name, null: false
      t.string :address
      t.decimal :latitude, precision: 10, scale: 8
      t.decimal :longitude, precision: 11, scale: 8
      t.text :boundary # Using TEXT for JSON in SQLite
      t.integer :lot_count, default: 0
      t.boolean :detected_from_satellite, default: false
      t.string :industry_type, default: 'both'
      t.string :created_by

      t.timestamps
    end

    # Lot Map Lots - Individual parking spaces/lots
    create_table :lot_map_lots do |t|
      t.integer :layout_id, null: false
      t.string :number, null: false
      t.text :position # Using TEXT for JSON in SQLite
      t.string :status, default: 'empty'
      t.integer :assigned_inventory_id
      t.string :assigned_inventory_info
      t.string :area
      t.text :notes

      t.timestamps
    end

    # Lot Map History - Audit trail for lot changes
    create_table :lot_map_history_entries do |t|
      t.integer :lot_id, null: false
      t.string :action, null: false
      t.integer :inventory_id
      t.string :old_status
      t.string :new_status
      t.integer :user_id
      t.string :user_name
      t.text :details

      t.timestamps
    end

    # Indexes
    add_index :lot_map_layouts, :company_id
    add_index :lot_map_layouts, :industry_type
    add_index :lot_map_layouts, :created_at

    add_index :lot_map_lots, :layout_id
    add_index :lot_map_lots, :number
    add_index :lot_map_lots, :status
    add_index :lot_map_lots, :assigned_inventory_id
    add_index :lot_map_lots, :created_at

    add_index :lot_map_history_entries, :lot_id
    add_index :lot_map_history_entries, :action
    add_index :lot_map_history_entries, :inventory_id
    add_index :lot_map_history_entries, :user_id
    add_index :lot_map_history_entries, :created_at

    # Foreign Keys
    add_foreign_key :lot_map_layouts, :companies, on_delete: :cascade
    add_foreign_key :lot_map_lots, :lot_map_layouts, column: :layout_id, on_delete: :cascade
    add_foreign_key :lot_map_history_entries, :lot_map_lots, column: :lot_id, on_delete: :cascade
  end
end
