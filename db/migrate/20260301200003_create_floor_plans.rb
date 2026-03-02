# frozen_string_literal: true

class CreateFloorPlans < ActiveRecord::Migration[8.0]
  def change
    create_table :floor_plans do |t|
      t.references :manufacturer, null: false, foreign_key: true
      t.references :factory, foreign_key: true
      t.string :name, null: false
      t.string :model_code, null: false
      t.string :series
      t.integer :beds
      t.decimal :baths, precision: 3, scale: 1
      t.integer :sqft
      t.decimal :width_feet, precision: 6, scale: 2
      t.decimal :length_feet, precision: 6, scale: 2
      t.jsonb :specifications, default: {}
      t.jsonb :images_array, default: []
      t.decimal :base_price_low, precision: 10, scale: 2
      t.decimal :base_price_high, precision: 10, scale: 2
      t.decimal :suggested_retail_low, precision: 10, scale: 2
      t.decimal :suggested_retail_high, precision: 10, scale: 2
      t.boolean :is_active, default: true, null: false
      t.string :scraper_source_url
      t.datetime :last_scraped_at

      t.timestamps
    end

    add_index :floor_plans, [:manufacturer_id, :model_code], unique: true
    add_index :floor_plans, :is_active
    add_index :floor_plans, :series
  end
end
