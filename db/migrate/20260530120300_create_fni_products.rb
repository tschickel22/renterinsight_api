# frozen_string_literal: true

# F&I products for the Deal Desk menu (service contract, GAP, tire/wheel, paint/fabric).
# default_cost is INTERNAL (feeds dealer back-end gross) — exclude from customer output.
# @company-scoped. Seeded samples are flagged is_seeded: true.
class CreateFniProducts < ActiveRecord::Migration[8.0]
  def change
    create_table :fni_products do |t|
      t.references :company, null: false, foreign_key: true, index: true
      t.string  :name,         null: false
      t.string  :product_type, null: false, default: 'other'  # service_contract|gap|tire_wheel|paint_fabric|other
      t.decimal :default_price, precision: 15, scale: 2, null: false, default: 0
      t.decimal :default_cost,  precision: 15, scale: 2, null: false, default: 0  # internal
      t.boolean :active,    null: false, default: true
      t.boolean :is_seeded, null: false, default: false
      t.integer :position,  null: false, default: 0
      t.timestamps
    end

    add_index :fni_products, [:company_id, :active]
  end
end
