# frozen_string_literal: true

# Company-level dealer-installed item defaults. Seeded from 21st Mortgage allowances.
# When a new lender is created, these defaults are copied into lender_allowance_items
# as that lender's starting schedule. Dealers can add custom items here too.
class CreateCompanyAllowanceDefaults < ActiveRecord::Migration[8.0]
  def change
    create_table :company_allowance_defaults do |t|
      t.references :company, null: false, foreign_key: true, index: true

      t.string  :category,  null: false  # Same CATEGORIES as LenderAllowanceItem
      t.string  :name,      null: false  # Human-readable label (e.g. "Air Conditioner")
      t.decimal :standard_allowance, precision: 15, scale: 2
      t.decimal :maximum_allowance,  precision: 15, scale: 2
      t.decimal :dealer_cost,        precision: 15, scale: 2  # What dealer pays contractor
      t.decimal :dealer_price,       precision: 15, scale: 2  # What dealer charges customer
      t.string  :pricing_basis       # flat/per_each/per_section_single/per_section_multi/per_material
      t.string  :material            # skirting variants: vinyl/metal/hardie/masonry
      t.decimal :wind_zone2_adder_per_side, precision: 15, scale: 2
      t.decimal :wind_zone3_adder_per_side, precision: 15, scale: 2
      t.boolean :is_seeded,  null: false, default: false
      t.boolean :active,     null: false, default: true
      t.integer :position,   null: false, default: 0

      t.timestamps
    end

    add_index :company_allowance_defaults, [:company_id, :category, :name],
              name: 'idx_company_allowance_defaults_uniq',
              unique: true
  end
end
