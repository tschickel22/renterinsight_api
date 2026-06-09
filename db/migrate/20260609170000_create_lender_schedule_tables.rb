class CreateLenderScheduleTables < ActiveRecord::Migration[8.0]
  def change
    # Per-lender ALLOWANCE schedule (Max Advance Phase 2). Company-scoped child of lenders.
    create_table :lender_allowance_items do |t|
      t.references :lender,  null: false, foreign_key: true, index: true
      t.references :company, null: false, foreign_key: true, index: true

      t.string  :category, null: false # options/delivery_set/trim_out/skirting/steps_decks/footers/pad/hookups/freight/ac/tax/hud_fees/gutters/other
      t.string  :name
      t.decimal :standard_allowance, precision: 15, scale: 2
      t.decimal :maximum_allowance,  precision: 15, scale: 2
      t.string  :pricing_basis # flat/per_each/per_section_single/per_section_multi/per_material
      t.string  :material      # skirting variants: vinyl/metal/hardie/masonry (nullable)
      # Spec lists one wind_zone_adder_per_side, but the 21st sheet needs distinct WZ2 (+500)
      # and WZ3 (+750) per-side adders for delivery_set, so we store both explicitly.
      t.decimal :wind_zone2_adder_per_side, precision: 15, scale: 2
      t.decimal :wind_zone3_adder_per_side, precision: 15, scale: 2
      t.boolean :active, null: false, default: true

      t.timestamps
    end

    # Per-lender DELETION schedule (configurable). Company-scoped child of lenders.
    create_table :lender_deletion_items do |t|
      t.references :lender,  null: false, foreign_key: true, index: true
      t.references :company, null: false, foreign_key: true, index: true

      t.string  :name, null: false # wheels_axles/factory_freight/dealer_rebate/ac/tax_from_invoice/hud_fees/packs/advertising/trim_out/other
      t.decimal :amount,        precision: 15, scale: 2 # nullable
      t.string  :invoice_reference # nullable — pulls from the invoice (e.g. factory_freight, sales_allowance)
      t.decimal :single_amount, precision: 15, scale: 2 # section-variant (e.g. wheels/axles SW $500)
      t.decimal :multi_amount,  precision: 15, scale: 2 # section-variant (e.g. wheels/axles DW $1000)
      t.boolean :active, null: false, default: true

      t.timestamps
    end

    # Per-lender MARKUP / VEP config (one per lender).
    create_table :lender_markup_configs do |t|
      t.references :lender,  null: false, foreign_key: true, index: { unique: true }
      t.references :company, null: false, foreign_key: true, index: true

      t.decimal :base_markup_pct,           precision: 8, scale: 2, default: 145
      t.integer :max_age_years,             default: 4
      t.decimal :vep0_adj_pct,              precision: 8, scale: 2, default: 5
      t.decimal :vep1_adj_pct,              precision: 8, scale: 2, default: 0
      t.decimal :vep2_adj_pct,              precision: 8, scale: 2, default: -5
      t.decimal :used_onsite_factor_pct,    precision: 8, scale: 2, default: 140
      t.decimal :used_delivered_factor_pct, precision: 8, scale: 2, default: 130

      t.timestamps
    end
  end
end
