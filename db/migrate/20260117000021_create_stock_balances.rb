# frozen_string_literal: true

class CreateStockBalances < ActiveRecord::Migration[8.0]
  def change
    create_table :stock_balances do |t|
      t.references :company, null: false, foreign_key: true
      t.references :part, null: false, foreign_key: true
      t.references :location, null: false, foreign_key: true
      t.references :bin, foreign_key: true
      
      # Quantities
      t.decimal :on_hand, precision: 10, scale: 3, default: 0, null: false
      t.decimal :reserved, precision: 10, scale: 3, default: 0, null: false
      t.decimal :available, precision: 10, scale: 3, default: 0, null: false
      
      # For serialized/lot tracking
      t.string :serial_number
      t.string :lot_number
      t.date :lot_expiration_date
      
      # Audit
      t.datetime :last_transaction_at
      t.timestamps
      
      # Unique constraint
      t.index [:company_id, :part_id, :location_id, :bin_id, :serial_number, :lot_number], 
              unique: true, 
              name: 'index_stock_balances_uniqueness'
      
      t.index [:company_id, :part_id]
      t.index [:company_id, :location_id]
      t.index [:part_id, :location_id]
      t.index :serial_number
      t.index :lot_number
    end
  end
end
