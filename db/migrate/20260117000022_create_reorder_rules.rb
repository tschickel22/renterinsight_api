# frozen_string_literal: true

class CreateReorderRules < ActiveRecord::Migration[8.0]
  def change
    create_table :reorder_rules do |t|
      t.references :company, null: false, foreign_key: true
      t.references :part, null: false, foreign_key: true
      t.references :location, null: false, foreign_key: true
      
      # Reorder thresholds
      t.decimal :reorder_point, precision: 10, scale: 3, null: false
      t.decimal :reorder_quantity, precision: 10, scale: 3
      t.decimal :maximum_stock, precision: 10, scale: 3
      
      # Status
      t.boolean :active, default: true
      
      t.timestamps
      
      # One rule per part/location
      t.index [:company_id, :part_id, :location_id], unique: true
      t.index [:company_id, :active]
    end
  end
end
