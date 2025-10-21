class CreateTerritoryUsers < ActiveRecord::Migration[8.0]
  def change
    create_table :territory_users do |t|
      t.references :territory, null: false, foreign_key: true
      t.references :user, null: false, foreign_key: true
      t.timestamps
    end

    # Add unique index to prevent duplicate assignments
    add_index :territory_users, [:territory_id, :user_id], unique: true
  end
end
