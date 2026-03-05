class CreatePackageTemplates < ActiveRecord::Migration[8.0]
  def change
    create_table :package_templates do |t|
      t.references :company, null: false, foreign_key: true
      t.string :name, null: false
      t.text :description
      t.decimal :default_price, precision: 12, scale: 2, default: 0
      t.boolean :include_in_total, default: true, null: false
      t.integer :position, default: 0, null: false
      t.boolean :is_active, default: true, null: false
      t.timestamps
    end

    add_index :package_templates, [:company_id, :is_active]
    add_index :package_templates, [:company_id, :position]
  end
end
