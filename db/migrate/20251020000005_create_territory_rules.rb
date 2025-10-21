class CreateTerritoryRules < ActiveRecord::Migration[7.0]
  def change
    create_table :territory_rules do |t|
      t.references :territory, null: false, foreign_key: true
      t.string :field, null: false
      t.string :operator, null: false
      t.string :value
      t.integer :priority, default: 0
      t.boolean :active, default: true

      t.timestamps
    end

    add_index :territory_rules, [:territory_id, :priority]
    add_index :territory_rules, :active
  end
end
