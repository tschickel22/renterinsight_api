# frozen_string_literal: true

# Adds Champion IMS sync support to the vehicles table.
#
# These columns enable the sync service to track which Vehicle records came
# from Champion, store the raw feed payload, and distinguish between
# dealer-owned images (existing :images column) and Champion-sourced images
# (:champion_images) so a sync never overwrites dealer uploads.
#
# IMPORTANT: Champion sync never writes outside the whitelist defined in
# Vehicle::CHAMPION_MANAGED_FIELDS. Pricing, status, stock_number, VIN,
# serial, and dealer images stay dealer-owned.
class AddChampionFieldsToVehicles < ActiveRecord::Migration[8.0]
  def change
    # Source of truth for where this inventory record came from.
    # Values: 'manual' (default, user-entered), 'champion_ims', 'box_import', 'csv_import'.
    add_column :vehicles, :source, :string, default: 'manual', null: false
    add_index  :vehicles, :source

    # Link to the shared FloorPlan catalog. When a Vehicle is imported from
    # a Champion FloorPlan, this FK is set so we can roll up specs and
    # find the source catalog entry later.
    add_reference :vehicles, :floor_plan, null: true, foreign_key: true, index: true

    # Champion's internal UUID for the home model. Used for dedup when
    # floor_plan linking isn't sufficient (e.g., historical imports).
    add_column :vehicles, :champion_model_id, :string
    add_index  :vehicles, :champion_model_id

    # Raw feed payload from Champion IMS - kept for debugging and future
    # field extraction without needing to re-scrape.
    add_column :vehicles, :champion_raw_payload, :jsonb, default: {}, null: false

    # Champion-supplied images, kept SEPARATE from :images (dealer uploads)
    # and :floor_plan_images (dealer-uploaded floor plan renderings).
    # Sync writes to this column only; dealer uploads are never touched.
    add_column :vehicles, :champion_images, :jsonb, default: [], null: false

    # Timestamp of the last time Champion IMS confirmed this home exists
    # in the feed. Used to detect removed homes (for tombstoning in
    # 'available_to_order' state only).
    add_column :vehicles, :champion_last_seen_at, :datetime
    add_index  :vehicles, :champion_last_seen_at
  end
end
