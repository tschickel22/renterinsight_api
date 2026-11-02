# frozen_string_literal: true

# A full comparison of schema.rb against production (2026-11-02) found one real bug
# and a pile of leftovers.
#
# The bug: 20260422000002 had its add_column commented out ("added manually"), which
# only ever happened on staging, so saving a draw schedule template failed on production.
#
# The foreign key below belongs on production. Everything removed here exists only on
# local databases (lot_map_* also on staging, empty), with no code using it, so this
# does nothing to production data and stops a schema dump from bringing them back.
#
# Do not add foreign keys from supplier_id to suppliers. Supplier is a Vendor, so those
# columns hold vendor ids and such a key would refuse real saves.
class AlignDatabaseWithSchemaAndAddTaxTiming < ActiveRecord::Migration[8.0]
  STRAY_COLUMNS = {
    companies: %i[branding_settings pipeline_stages],
    land_parcels: %i[boundary_area_sq_ft boundary_geojson has_boundary],
    parts: %i[manufacturer_id],
    resources: %i[display_order],
    service_tickets: %i[completed_date customer_id customer_type deleted_at],
    vehicles: %i[public_id]
  }.freeze

  def up
    add_column :draw_schedule_templates, :tax_timing, :string, default: 'per_draw', null: false, if_not_exists: true

    add_foreign_key :inventory_transactions, :purchase_order_lines, if_not_exists: true

    STRAY_COLUMNS.each do |table, columns|
      columns.each { |column| remove_column table, column, if_exists: true }
    end

    drop_table :lot_map_history_entries, if_exists: true
    drop_table :lot_map_lots, if_exists: true
    drop_table :lot_map_layouts, if_exists: true
  end

  def down; end
end
