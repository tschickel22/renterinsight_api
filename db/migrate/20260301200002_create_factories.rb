# frozen_string_literal: true

class CreateFactories < ActiveRecord::Migration[8.0]
  def change
    create_table :factories do |t|
      t.references :manufacturer, null: false, foreign_key: true
      t.string :name, null: false
      t.string :code, null: false
      t.string :address
      t.string :city
      t.string :state
      t.string :zip
      t.decimal :latitude, precision: 10, scale: 7
      t.decimal :longitude, precision: 10, scale: 7
      t.string :contact_email
      t.string :contact_phone
      t.boolean :is_active, default: true, null: false

      t.timestamps
    end

    add_index :factories, [:manufacturer_id, :code], unique: true
    add_index :factories, :is_active
  end
end
