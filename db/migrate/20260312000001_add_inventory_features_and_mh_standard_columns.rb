class AddInventoryFeaturesAndMhStandardColumns < ActiveRecord::Migration[8.0]
  def change
    create_table :inventory_features do |t|
      t.references :vehicle, null: false, foreign_key: true
      t.references :company, null: false, foreign_key: true
      t.string     :name,       null: false
      t.string     :category
      t.boolean    :is_standard, default: true
      t.timestamps
    end

    add_index :inventory_features, [:vehicle_id, :name], unique: true, name: 'idx_inv_features_vehicle_name'
    add_index :inventory_features, [:company_id, :name],               name: 'idx_inv_features_company_name'
    add_index :inventory_features, :category,                          name: 'idx_inv_features_category'

    add_column :vehicles, :insulation_r_roof,       :string, comment: 'Roof insulation R-value (e.g. R-28, R-40)'
    add_column :vehicles, :insulation_r_wall,       :string, comment: 'Wall insulation R-value (e.g. R-11, R-19)'
    add_column :vehicles, :insulation_r_floor,      :string, comment: 'Floor insulation R-value (e.g. R-11)'
    add_column :vehicles, :floor_joist_size,        :string, comment: 'Floor joist dimensions (e.g. 2x6, 2x8, 2x10)'
    add_column :vehicles, :electrical_service,      :string, comment: 'Electrical service rating (e.g. 100 AMP, 200 AMP)'
    add_column :vehicles, :modular_conversion_cost, :decimal, precision: 10, scale: 2, comment: 'Cost for modular conversion package'
  end
end
