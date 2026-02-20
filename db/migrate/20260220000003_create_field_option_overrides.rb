class CreateFieldOptionOverrides < ActiveRecord::Migration[8.0]
  def change
    create_table :field_option_overrides do |t|
      t.references :company, null: false, foreign_key: true
      t.string :module_name, null: false
      t.string :field_key, null: false
      t.jsonb :options, null: false, default: []

      t.timestamps
    end

    add_index :field_option_overrides, [:company_id, :module_name, :field_key], unique: true, name: 'idx_field_option_overrides_unique'
  end
end
