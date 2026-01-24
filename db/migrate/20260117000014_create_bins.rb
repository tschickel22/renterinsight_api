# frozen_string_literal: true

class CreateBins < ActiveRecord::Migration[8.0]
  def change
    # Drop any orphaned indexes from previous failed attempts
    execute "DROP INDEX IF EXISTS index_bins_on_location_id" rescue nil
    execute "DROP INDEX IF EXISTS index_bins_on_location_id_and_bin_code" rescue nil
    execute "DROP INDEX IF EXISTS index_bins_on_location_id_and_active" rescue nil
    execute "DROP INDEX IF EXISTS index_bins_on_location_id_and_is_default" rescue nil
    execute "DROP INDEX IF EXISTS index_bins_on_bin_type" rescue nil
    
    return if table_exists?(:bins)
    
    create_table :bins do |t|
      t.references :location, null: false, foreign_key: true
      
      # Bin identification
      t.string :bin_code, null: false
      t.string :label
      t.string :bin_type, default: 'standard'
      
      # Physical details (optional)
      t.decimal :capacity_cubic_feet, precision: 10, scale: 2
      t.text :notes
      
      # Status
      t.boolean :is_default, default: false
      t.boolean :active, default: true
      t.boolean :is_deleted, default: false
      t.datetime :deleted_at
      
      # Custom fields support
      t.jsonb :custom_fields, default: {}
      
      t.timestamps
      
      t.index [:location_id, :bin_code], unique: true, where: "is_deleted = false"
      t.index [:location_id, :active]
      t.index [:location_id, :is_default]
      t.index :bin_type
    end
  end
end
