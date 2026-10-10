class CreateLandHomePackages < ActiveRecord::Migration[8.0]
  # A lot and a home sold together. Several homes can be offered on one lot,
  # and one home on several lots, so each pairing is its own row with its own
  # price and words.
  def change
    create_table :land_home_packages do |t|
      t.references :company, null: false, foreign_key: true
      t.references :land_parcel, null: false, foreign_key: true
      t.references :vehicle, null: false, foreign_key: true
      t.string :name
      t.decimal :price, precision: 15, scale: 2
      t.text :description
      t.boolean :show_on_website, default: true, null: false
      t.integer :position, default: 0, null: false
      t.timestamps
    end

    add_index :land_home_packages, [:land_parcel_id, :vehicle_id], unique: true
  end
end
