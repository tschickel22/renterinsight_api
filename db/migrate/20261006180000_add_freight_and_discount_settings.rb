# frozen_string_literal: true

# The deal sheet (E49/E50): freight worked out from miles and the home's
# sections, and the buyer discounts Factory Direct's quote desk applies.
#
# Freight settings are the dealer's (their hauler, not the factory, sets the
# rates); until they set them, the deal sheet uses stated assumptions
# (DealerCatalogTerm::FREIGHT_ASSUMPTIONS). freight_per_mile now means per
# mile per section; no dealer had set it.
#
# Discount defaults are per manufacturer; the amounts on a deal live in the
# deal's existing discount columns, which agreements already merge.
class AddFreightAndDiscountSettings < ActiveRecord::Migration[8.0]
  def change
    change_table :dealer_catalog_terms, bulk: true do |t|
      t.decimal :freight_permit_per_section, precision: 10, scale: 2
      t.decimal :freight_escort_per_mile, precision: 10, scale: 2
      t.integer :freight_escort_width_ft
      t.decimal :freight_minimum, precision: 12, scale: 2
      t.decimal :freight_markup_pct, precision: 7, scale: 4
      t.decimal :sale_discount_pct, precision: 7, scale: 4
      t.decimal :dealer_savings_pct, precision: 7, scale: 4
      t.decimal :preferred_payment_pct, precision: 7, scale: 4
    end

    change_table :deal_home_builds, bulk: true do |t|
      # Miles from the plant to the homesite: estimated, or what the rep typed.
      t.integer :freight_miles
      t.boolean :freight_miles_set, null: false, default: false
      # Discount inputs (percents and dollars); amounts are written to the deal.
      t.jsonb :discounts, null: false, default: {}
    end

    # A line from the dealer's fee or package templates, the ones Products and
    # the Deal Desk offer.
    add_reference :deal_home_build_lines, :source_template, polymorphic: true
  end
end
