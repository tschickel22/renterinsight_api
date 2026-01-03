# frozen_string_literal: true

class AddDefaultPackToCompaniesAndLocations < ActiveRecord::Migration[8.0]
  def change
    add_column :companies, :default_pack_amount, :decimal, precision: 15, scale: 2, default: 0
    add_column :locations, :default_pack_amount, :decimal, precision: 15, scale: 2
    
    add_index :companies, :default_pack_amount
    add_index :locations, :default_pack_amount
  end
end
