# frozen_string_literal: true

# Adds an explicit `source_type` discriminator to deal_products. Today the table
# is generic — a "Primary Vehicle" row and a parts row look identical in the
# schema, and downstream code has to label-match (product_name) or pattern-match
# the SKU (`VEHICLE-<id>`) to tell them apart. That heuristic shipped a bug
# (Deal 105) where a vehicle line item existed but deal.vehicle_id was NULL.
#
# Adding source_type lets writers tag rows explicitly going forward and lets
# readers (status sync, GL posting, invoicing) branch off a real column instead
# of fragile string matching. Column is nullable so this migration is purely
# additive — wire-up of writers and readers can land incrementally.
#
# Expected values once writers start populating it:
#   'vehicle'    — line item represents an inventory vehicle (VEHICLE-<id> SKU)
#   'part'       — parts/accessories line item
#   'fee'        — doc fee, delivery, setup, etc.
#   'fni'        — F&I product (warranty, GAP, etc.)
#   'discount'   — discount/credit line
#   'custom'     — manually-entered free-text line
#
# Backfill for existing rows lives in a separate rake task so it can be run
# (and re-run, idempotently) on staging/prod independent of migration timing.
class AddSourceTypeToDealProducts < ActiveRecord::Migration[8.0]
  def change
    add_column :deal_products, :source_type, :string
    add_index :deal_products, :source_type
  end
end
