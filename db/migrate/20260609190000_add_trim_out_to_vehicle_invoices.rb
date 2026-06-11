class AddTrimOutToVehicleInvoices < ActiveRecord::Migration[8.0]
  # Manufacturer invoices can carry a separate Trim Out / Tape & Texture line (e.g. the
  # multi-section Sunshine PRI3280 invoice: $10,900). Like freight/HUD it is stripped from
  # the markup base (a deletion) and added back at cost, so it must be captured on the
  # invoice. Phase 1 omitted it; the Phase 3 worksheet tie-out surfaced the gap.
  def change
    add_column :vehicle_invoices, :trim_out, :decimal, precision: 15, scale: 2
  end
end
