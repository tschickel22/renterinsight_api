class CreateCompanyManufacturers < ActiveRecord::Migration[8.0]
  def change
    create_table :company_manufacturers do |t|
      t.references :company, null: false, foreign_key: true
      t.references :manufacturer, null: false, foreign_key: true
      t.string :dealer_code
      t.boolean :active, default: true, null: false
      t.text :notes
      t.jsonb :metadata, default: {}

      t.timestamps
    end

    add_index :company_manufacturers, [:company_id, :manufacturer_id], unique: true, name: 'index_company_manufacturers_on_company_and_manufacturer'
    add_index :company_manufacturers, :active
  end
end
