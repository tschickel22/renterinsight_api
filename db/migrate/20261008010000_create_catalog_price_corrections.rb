# frozen_string_literal: true

# Correcting a published price book (backlog E49 follow-up). A platform admin
# fixes a wrong base or option price in place; it reaches every dealer on the
# book at once (a fix, not a new price list), and each change is logged.
# A dealer who finds a wrong price sets it on the deal and reports it here.
class CreateCatalogPriceCorrections < ActiveRecord::Migration[8.0]
  def change
    create_table :catalog_price_corrections do |t|
      t.references :catalog_price_book, null: false, foreign_key: true
      # CatalogVariantPrice (a model's base) or CatalogOptionPrice.
      t.string :target_type, null: false
      t.bigint :target_id, null: false
      t.string :field, null: false
      t.string :old_value
      t.string :new_value
      t.text :reason
      t.references :corrected_by, foreign_key: { to_table: :users }
      t.references :catalog_price_request, foreign_key: false
      t.datetime :created_at, null: false
    end
    add_index :catalog_price_corrections, %i[target_type target_id]

    create_table :catalog_price_requests do |t|
      t.references :company, null: false, foreign_key: true
      t.references :catalog_price_book, null: false, foreign_key: true
      t.string :target_type, null: false
      t.bigint :target_id, null: false
      # price (suggested retail) or cost (dealer cost / base price).
      t.string :field, null: false
      t.decimal :current_value, precision: 12, scale: 2
      t.decimal :suggested_value, precision: 12, scale: 2
      t.text :note
      t.string :label, null: false
      t.references :deal, foreign_key: true
      t.references :requested_by, foreign_key: { to_table: :users }
      t.string :status, null: false, default: 'open' # open | applied | dismissed
      t.references :resolved_by, foreign_key: { to_table: :users }
      t.datetime :resolved_at
      t.text :resolution_note
      t.timestamps
    end
    add_index :catalog_price_requests, %i[status catalog_price_book_id]
  end
end
