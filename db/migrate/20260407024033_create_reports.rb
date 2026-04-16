class CreateReports < ActiveRecord::Migration[8.0]
  def change
    create_table :reports do |t|
      t.string :name
      t.text :description
      t.string :module_key
      t.jsonb :config
      t.string :status
      t.integer :company_id
      t.integer :user_id
      t.integer :location_id
      t.boolean :is_favorite
      t.boolean :is_deleted

      t.timestamps
    end

    add_index :reports, [:company_id, :module_key]
  end
end
