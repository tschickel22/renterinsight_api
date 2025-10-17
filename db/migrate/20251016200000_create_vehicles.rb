# frozen_string_literal: true

class CreateVehicles < ActiveRecord::Migration[8.0]
  def change
    create_table :vehicles do |t|
      t.references :company, foreign_key: true
      t.string :stock_number
      t.string :vin
      t.integer :year
      t.string :make
      t.string :model
      t.string :trim
      t.string :color
      t.string :condition, default: 'new' # new, used
      t.string :status, default: 'available' # available, sold, pending, reserved
      t.decimal :price, precision: 15, scale: 2
      t.decimal :cost, precision: 15, scale: 2
      t.integer :mileage
      t.text :description
      t.text :notes
      t.json :features, default: []
      t.string :location
      t.datetime :date_in_stock
      t.datetime :date_sold
      t.boolean :is_deleted, default: false, null: false
      t.datetime :deleted_at

      t.timestamps
    end

    add_index :vehicles, :stock_number, unique: true
    add_index :vehicles, :vin, unique: true
    add_index :vehicles, :status
    add_index :vehicles, :condition
    add_index :vehicles, :is_deleted
    add_index :vehicles, [:year, :make, :model]
  end
end
