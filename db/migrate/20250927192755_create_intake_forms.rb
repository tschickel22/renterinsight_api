class CreateIntakeForms < ActiveRecord::Migration[8.0]
  def change
    create_table :intake_forms do |t|
      t.string :name
      t.text :description
      t.json :schema
      t.boolean :is_active

      t.timestamps
    end
  end
end
