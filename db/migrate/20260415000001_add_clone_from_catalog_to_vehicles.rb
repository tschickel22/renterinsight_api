# frozen_string_literal: true

# Adds clone-from-catalog support for Champion IMS.
#
# Architecture (per Tom's spec, 2026-04-15):
#
#   - Champion IMS feed creates Vehicle rows with `source: 'champion_ims'`
#     and `status: 'available_to_order'`. These are the catalog. Sync is the
#     only writer; dealers cannot edit them in place.
#
#   - When a dealer changes the status of a catalog row to anything other
#     than `available_to_order`, the system intercepts the update and clones
#     the row instead. The clone gets `source: 'champion_ims_clone'`,
#     `cloned_from_id` pointing back to the catalog row, and the requested
#     new status. The original catalog row stays pristine and continues to
#     receive sync updates.
#
#   - Brochures, quotes, deals, listings, etc. that reference the catalog
#     row directly continue to work. Cloning happens only on STATUS CHANGE,
#     not on use-in-brochure / use-in-quote.
#
# Also adds `apply_to_all_locations` to `champion_ims_retailers` so a single
# feed can serve all locations of a multi-location dealer (Option C from
# Tom's spec — single retailer record, optional location, plus a flag for
# company-wide visibility).
class AddCloneFromCatalogToVehicles < ActiveRecord::Migration[8.0]
  def change
    # Vehicle: cloned_from_id (FK to vehicles.id, nullable, indexed)
    add_reference :vehicles, :cloned_from,
                  foreign_key: { to_table: :vehicles },
                  index: true,
                  null: true,
                  comment: 'For Champion IMS clones: points to the catalog Vehicle this row was cloned from'

    # Retailer: apply_to_all_locations boolean (default false)
    add_column :champion_ims_retailers, :apply_to_all_locations, :boolean,
               default: false, null: false,
               comment: 'When true, synced vehicles are company-wide (location_id=nil) regardless of retailer.location_id'
  end
end
