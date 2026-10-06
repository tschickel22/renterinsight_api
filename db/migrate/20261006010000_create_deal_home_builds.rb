# frozen_string_literal: true

# The home on a deal and what was chosen for it (backlog E49): the factory
# model, each option with quantity, cost and retail, TBD and N/C, standard or
# upgrade finish picks, freight and the dealer's add-ons. Schedule A, Colors &
# Finishes, the deal sheet and the factory PO all read it. Its own record, not
# a buyer's saved design: a rep's working build needs quantities, TBD and N/C
# that a design does not.
class CreateDealHomeBuilds < ActiveRecord::Migration[8.0]
  def change
    create_table :deal_home_builds do |t|
      t.references :company, null: false, foreign_key: true
      t.references :deal, null: false, foreign_key: true, index: { unique: true }
      t.references :location, foreign_key: true
      t.references :catalog_plan_variant, null: false, foreign_key: true
      # The home on the lot it is; nil for a factory order.
      t.references :vehicle, foreign_key: true
      t.string :source, null: false, default: 'order' # order | lot
      t.references :truebuild_design, foreign_key: true
      # The books it was last priced from: base, base cost, options.
      t.references :catalog_price_book, foreign_key: true
      t.references :cost_book, foreign_key: { to_table: :catalog_price_books }
      t.references :options_book, foreign_key: { to_table: :catalog_price_books }
      t.string :construction
      t.string :status, null: false, default: 'draft' # draft | locked
      t.datetime :priced_at
      t.jsonb :totals, null: false, default: {}
      t.text :notes
      t.references :created_by, foreign_key: { to_table: :users }
      t.timestamps
    end

    create_table :deal_home_build_lines do |t|
      t.references :deal_home_build, null: false, foreign_key: { on_delete: :cascade }
      t.string :kind, null: false # base | option | freight | addon | custom
      t.references :catalog_option, foreign_key: true
      t.references :truebuild_addon, foreign_key: true
      # Snapshots, so a later book cannot rename or regroup a signed line.
      t.string :group_name
      t.string :label, null: false
      t.string :factory_code
      t.decimal :quantity, precision: 10, scale: 2, null: false, default: 1
      t.string :unit, null: false, default: 'each' # each | lf | sf
      t.decimal :unit_cost, precision: 12, scale: 2
      t.decimal :unit_retail, precision: 12, scale: 2
      t.decimal :cost, precision: 12, scale: 2
      t.decimal :retail, precision: 12, scale: 2
      t.boolean :is_standard, null: false, default: false
      # Chosen, price not settled: kept out of totals and flagged.
      t.boolean :tbd, null: false, default: false
      # No charge to the buyer; the cost still counts against gross.
      t.boolean :no_charge, null: false, default: false
      # Read by the state tax rules (E45).
      t.string :tax_category, null: false, default: 'factory_option'
      t.integer :position, null: false, default: 0
      t.jsonb :metadata, null: false, default: {}
      t.timestamps
    end
    add_index :deal_home_build_lines, %i[deal_home_build_id position]
  end
end
