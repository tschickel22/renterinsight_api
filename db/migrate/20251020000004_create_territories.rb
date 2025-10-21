class CreateTerritories < ActiveRecord::Migration[7.0]
  def change
    create_table :territories do |t|
      t.string :name, null: false
      t.text :description
      t.references :user, foreign_key: true  # This already creates user_id index
      t.string :region
      t.string :type_field

      t.timestamps
    end

    add_index :territories, :name, unique: true
    # Removed duplicate user_id index - t.references already creates it
  end
end
