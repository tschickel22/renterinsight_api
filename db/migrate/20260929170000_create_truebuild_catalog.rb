# frozen_string_literal: true

# TrueBuild catalog and dealer pricing.
#
# Everything named catalog_* is PLATFORM data: no company_id. Platform admins
# import a factory's price package once and every dealer subscribed to that
# manufacturer prices from it. Dealers own only the dealer_* layer (markup,
# terms, which price book they have adopted).
#
# Shape, from the Champion Topeka package:
#   catalog_plans          a plan family ("Belvidere"), spanning sizes and codes
#   catalog_plan_variants  one factory model number (2856H32392 is HUD,
#                          2856M32392 is the modular build of the same plan)
#   catalog_price_books    one dated import for one plant; prices hang off it,
#                          so publishing a new book never rewrites an old quote
#   catalog_import_items   what extraction proposed, awaiting admin review
#
# The March 2026 configurator tables (floor_plans, option_categories, ...) are
# left alone here; retiring them is a separate change.
class CreateTruebuildCatalog < ActiveRecord::Migration[8.0]
  def change
    create_table :catalog_plans do |t|
      t.references :manufacturer, null: false, foreign_key: true
      t.references :factory, foreign_key: true
      t.string :series, null: false
      t.string :name, null: false
      t.string :slug, null: false
      # Informational. Codes repeat across sizes with different plans on some
      # sheets (Prime's P01 is Peak at 14x56 and Crest at 14x60).
      t.string :plan_code
      t.text :description
      t.string :status, null: false, default: 'active'
      t.jsonb :metadata, null: false, default: {}
      t.timestamps
    end
    add_index :catalog_plans, [:manufacturer_id, :series, :slug], unique: true

    create_table :catalog_plan_variants do |t|
      t.references :catalog_plan, null: false, foreign_key: true
      t.references :manufacturer, null: false, foreign_key: true
      # Normalized (see Catalog::ModelNumber); the sheet's spelling is kept too
      # because scans confuse O and 0.
      t.string :model_number, null: false
      t.string :model_number_as_printed
      t.string :building_code, null: false
      t.integer :width_ft
      t.integer :length_ft
      t.integer :beds
      t.decimal :baths, precision: 3, scale: 1
      t.integer :square_feet
      t.string :home_type
      t.string :status, null: false, default: 'active'
      # Links to outside catalogs, e.g. { "champion_model_id" => "...", "champion_slug" => "aspire-belvidere" }
      t.jsonb :external_ids, null: false, default: {}
      t.timestamps
    end
    add_index :catalog_plan_variants, [:manufacturer_id, :model_number], unique: true

    add_reference :vehicles, :catalog_plan_variant, foreign_key: true

    create_table :catalog_price_books do |t|
      t.references :manufacturer, null: false, foreign_key: true
      t.references :factory, foreign_key: true
      t.string :name, null: false
      t.string :status, null: false, default: 'draft'
      t.date :effective_on
      t.datetime :published_at
      t.references :published_by, foreign_key: { to_table: :users }
      t.references :created_by, foreign_key: { to_table: :users }
      t.references :supersedes, foreign_key: { to_table: :catalog_price_books }
      t.text :notes
      t.jsonb :metadata, null: false, default: {}
      t.timestamps
    end
    add_index :catalog_price_books, [:manufacturer_id, :status]
    add_index :catalog_price_books, [:manufacturer_id, :factory_id],
              unique: true, where: "status = 'published'",
              name: 'idx_catalog_price_books_one_published'

    # Source files. Dealer net pricing is confidential, so these live in a
    # private bucket, never the public website-assets bucket.
    create_table :catalog_price_book_documents do |t|
      t.references :catalog_price_book, null: false, foreign_key: true
      t.string :filename, null: false
      t.string :content_type
      t.bigint :byte_size
      t.string :checksum_sha256, null: false
      t.string :storage_bucket
      t.string :storage_key
      t.string :kind, null: false, default: 'unknown'
      t.integer :page_count
      t.string :extraction_status, null: false, default: 'pending'
      t.text :extraction_error
      t.datetime :extracted_at
      t.jsonb :metadata, null: false, default: {}
      t.timestamps
    end
    add_index :catalog_price_book_documents, [:catalog_price_book_id, :checksum_sha256],
              unique: true, name: 'idx_catalog_pb_documents_unique_file'

    create_table :catalog_import_items do |t|
      t.references :catalog_price_book, null: false, foreign_key: true
      t.references :catalog_price_book_document, foreign_key: true
      t.string :item_type, null: false
      t.jsonb :payload, null: false, default: {}
      # Where it came from: { "page" => 2 } or { "sheet" => "DGAE - HUD", "cells" => ["G177", "H177"] }
      t.jsonb :source_ref, null: false, default: {}
      # Automatic checks that fired, e.g. ["model_code_beds_mismatch"]
      t.jsonb :flags, null: false, default: []
      t.string :change_type
      t.jsonb :previous_values
      t.string :review_status, null: false, default: 'pending'
      t.references :reviewed_by, foreign_key: { to_table: :users }
      t.datetime :reviewed_at
      t.references :matched, polymorphic: true
      t.timestamps
    end
    add_index :catalog_import_items, [:catalog_price_book_id, :review_status]
    add_index :catalog_import_items, [:catalog_price_book_id, :item_type]

    create_table :catalog_variant_prices do |t|
      t.references :catalog_price_book, null: false, foreign_key: true
      t.references :catalog_plan_variant, null: false, foreign_key: true
      t.decimal :net_base_price, precision: 12, scale: 2, null: false
      # Charges the factory requires on top of base, e.g. modular conversion:
      # [{ "name" => "Rugged MOD Conversion 2x10", "amount" => "3150.0" }]
      t.jsonb :required_adders, null: false, default: []
      t.decimal :total_base_price, precision: 12, scale: 2
      t.jsonb :source_ref, null: false, default: {}
      t.timestamps
    end
    add_index :catalog_variant_prices, [:catalog_price_book_id, :catalog_plan_variant_id],
              unique: true, name: 'idx_catalog_variant_prices_unique'

    create_table :catalog_option_groups do |t|
      t.references :manufacturer, null: false, foreign_key: true
      t.references :factory, foreign_key: true
      # Blank means every series at this plant.
      t.string :series
      t.string :key, null: false
      t.string :name, null: false
      t.string :selection_type, null: false, default: 'single'
      t.boolean :required, null: false, default: false
      t.integer :position, null: false, default: 0
      # Which photo surface this group repaints in TrueView (cabinets, countertop, siding).
      t.string :render_surface
      t.timestamps
    end
    add_index :catalog_option_groups,
              'manufacturer_id, COALESCE(factory_id, 0), COALESCE(series, \'\'), key',
              unique: true, name: 'idx_catalog_option_groups_unique_key'

    create_table :catalog_options do |t|
      t.references :catalog_option_group, null: false, foreign_key: true
      t.references :manufacturer, null: false, foreign_key: true
      # Our stable id. Champion order forms carry no option codes, so we cannot
      # rely on factory_code being present.
      t.string :key, null: false
      t.string :factory_code
      t.string :name, null: false
      t.text :description
      t.string :kind, null: false, default: 'upgrade'
      # For swaps ("IPO", "T/O"): the standard item it replaces.
      t.string :in_place_of
      t.jsonb :package_items, null: false, default: []
      t.string :swatch_url
      t.string :render_surface
      # SVG layer the floor plan shows when this option is chosen.
      t.string :floor_plan_layer
      t.string :status, null: false, default: 'active'
      t.date :discontinued_on
      t.references :replaced_by, foreign_key: { to_table: :catalog_options }
      t.integer :position, null: false, default: 0
      t.jsonb :metadata, null: false, default: {}
      t.timestamps
    end
    add_index :catalog_options, [:manufacturer_id, :key], unique: true
    add_index :catalog_options, [:manufacturer_id, :factory_code]

    # One option can carry several prices: by box length, single or multi,
    # construction, building code, or one specific model.
    create_table :catalog_option_prices do |t|
      t.references :catalog_price_book, null: false, foreign_key: true
      t.references :catalog_option, null: false, foreign_key: true
      t.decimal :dealer_cost, precision: 12, scale: 2
      t.decimal :suggested_retail, precision: 12, scale: 2
      t.boolean :is_standard, null: false, default: false
      t.references :catalog_plan_variant, foreign_key: true
      t.string :series
      t.integer :min_length_ft
      t.integer :max_length_ft
      t.integer :width_ft
      t.string :section_type
      t.string :construction
      t.string :building_code
      t.jsonb :source_ref, null: false, default: {}
      t.timestamps
    end
    add_index :catalog_option_prices, [:catalog_price_book_id, :catalog_option_id],
              name: 'idx_catalog_option_prices_book_option'

    create_table :catalog_option_rules do |t|
      t.references :manufacturer, null: false, foreign_key: true
      t.references :catalog_option, null: false, foreign_key: true
      t.string :rule_type, null: false
      t.references :target_option, null: false, foreign_key: { to_table: :catalog_options }
      t.jsonb :conditions, null: false, default: {}
      t.jsonb :source_ref, null: false, default: {}
      t.text :notes
      t.datetime :approved_at
      t.references :approved_by, foreign_key: { to_table: :users }
      t.timestamps
    end
    add_index :catalog_option_rules, [:catalog_option_id, :rule_type, :target_option_id],
              unique: true, name: 'idx_catalog_option_rules_unique'

    create_table :catalog_standard_features do |t|
      t.references :catalog_price_book, null: false, foreign_key: true
      t.string :series
      t.string :building_code
      t.string :category, null: false
      t.string :name, null: false
      t.integer :position, null: false, default: 0
      t.timestamps
    end
    add_index :catalog_standard_features, [:catalog_price_book_id, :series]

    # ---- Dealer layer (tenant data) ----

    # A dealer's terms, company-wide (manufacturer_id NULL) or per manufacturer.
    create_table :dealer_catalog_terms do |t|
      t.references :company, null: false, foreign_key: true
      t.references :manufacturer, foreign_key: true
      t.string :price_update_policy, null: false, default: 'review'
      # Hidden until the dealer chooses; some factory agreements restrict advertised prices.
      t.string :price_display, null: false, default: 'hidden'
      t.decimal :program_discount_pct, precision: 7, scale: 4, null: false, default: 0
      t.decimal :freight_per_mile, precision: 10, scale: 2
      t.decimal :freight_flat, precision: 12, scale: 2
      t.decimal :margin_floor_pct, precision: 7, scale: 4
      t.integer :round_retail_to
      t.timestamps
    end
    add_index :dealer_catalog_terms, 'company_id, COALESCE(manufacturer_id, 0)',
              unique: true, name: 'idx_dealer_catalog_terms_unique'

    # Markup, most specific scope wins. A company-wide 1.30 multiplier, a
    # different one for options, a manual retail on one plan.
    create_table :dealer_markup_rules do |t|
      t.references :company, null: false, foreign_key: true
      t.references :location, foreign_key: true
      t.string :scope_type, null: false
      t.references :manufacturer, foreign_key: true
      # Series name when scope_type is series.
      t.string :scope_value
      # Plan, variant, option group or option id, per scope_type.
      t.bigint :scope_id
      t.string :applies_to, null: false, default: 'base_and_options'
      # percent (30 = 30% over cost), multiplier (1.30), flat (dollars added) or manual (retail price)
      t.string :markup_type, null: false
      t.decimal :value, precision: 12, scale: 4, null: false
      t.boolean :active, null: false, default: true
      t.timestamps
    end
    add_index :dealer_markup_rules,
              "company_id, COALESCE(location_id, 0), scope_type, COALESCE(manufacturer_id, 0), " \
              "COALESCE(scope_value, ''), COALESCE(scope_id, 0), applies_to",
              unique: true, name: 'idx_dealer_markup_rules_unique_scope'

    # Which published price book a dealer is pricing from, when their policy
    # holds new books for review.
    create_table :dealer_price_book_adoptions do |t|
      t.references :company, null: false, foreign_key: true
      t.references :catalog_price_book, null: false, foreign_key: true
      t.string :status, null: false, default: 'pending'
      t.datetime :decided_at
      t.references :decided_by, foreign_key: { to_table: :users }
      t.timestamps
    end
    add_index :dealer_price_book_adoptions, [:company_id, :catalog_price_book_id],
              unique: true, name: 'idx_dealer_pb_adoptions_unique'
  end
end
