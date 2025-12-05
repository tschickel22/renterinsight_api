class CreateLocationManufacturers < ActiveRecord::Migration[8.0]
  def change
    create_table :location_manufacturers do |t|
      t.references :location, null: false, foreign_key: true
      t.references :manufacturer, null: false, foreign_key: true
      t.string :dealer_code
      t.boolean :active, default: true, null: false
      t.text :notes
      t.jsonb :metadata, default: {}

      t.timestamps
    end

    add_index :location_manufacturers, [:location_id, :manufacturer_id], unique: true, name: 'index_location_manufacturers_on_location_and_manufacturer'
    add_index :location_manufacturers, :active
  end
end
