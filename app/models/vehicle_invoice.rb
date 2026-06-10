# frozen_string_literal: true

# VehicleInvoice — structured capture of a manufacturer's invoice for ONE vehicle
# (Max Advance Phase 1, manual entry). A child record rather than more columns on
# vehicles. INTERNAL-ONLY: cost-basis data, never exposed on any customer-facing or
# marketing surface. The optional scanned invoice file is a VehicleDocument flagged
# visibility:'internal'.
#
# Phase 1 is capture only — no calculator, lender schedule, surfacing, or scan.
class VehicleInvoice < ApplicationRecord
  belongs_to :vehicle
  belongs_to :company
  # The scanned manufacturer invoice, when present, is an internal-only document.
  belongs_to :scanned_document, class_name: 'VehicleDocument', optional: true

  # Money fields — numeric, optional during manual entry. sales_allowance is stored
  # NEGATIVE (it's a rebate/allowance that reduces cost).
  NUMERIC_FIELDS = %i[
    gross_invoice base_price options_total material_surcharge factory_freight
    sales_allowance hud_fees state_assoc_fees tax_from_invoice total_invoice nada_base
    trim_out
  ].freeze

  # One invoice per vehicle (also enforced by a unique DB index).
  validates :vehicle_id, uniqueness: true

  NUMERIC_FIELDS.each do |field|
    validates field, numericality: true, allow_nil: true
  end

  validates :vep_code,  inclusion: { in: 0..2 }, allow_nil: true
  validates :wind_zone, inclusion: { in: 1..3 }, allow_nil: true

  # If a scanned invoice document is linked, it must belong to this vehicle/company and
  # be internal-only — the invoice scan never rides on a customer/public document tier.
  validate :scanned_document_is_internal_and_owned, if: -> { scanned_document_id.present? }

  # Seed the vehicle's Home Cost (dealer_cost) from this invoice ONLY when the dealer
  # hasn't entered any Cost Details yet. The invoice total is a reasonable starting cost
  # basis (for a new home the dealer typically pays the invoice), so this saves re-entry
  # and lets cost flow to deals/GP. It NEVER overwrites an entered cost — dealer_cost,
  # freight_cost, pdi_cost, and total_cost are all checked. The seeded value is a normal,
  # editable dealer_cost the rep can correct if the invoice isn't the true cost (the
  # Cost Details tooltip says so). This keeps structured_cost (the GP/commission spine)
  # honest — we populate a real field rather than having the cost method guess from the invoice.
  after_save :seed_vehicle_cost_from_invoice

  private

  def seed_vehicle_cost_from_invoice
    v = vehicle
    return unless v
    # Only seed when NO cost detail exists (flag-don't-guess: never clobber a real entry).
    return if v.dealer_cost.to_f.positive? || v.freight_cost.to_f.positive? ||
              v.pdi_cost.to_f.positive? || v.total_cost.to_f.positive?

    # Use the manufacturer's GROSS invoice as the cost basis — it's the top-line invoice
    # amount (what the dealer is invoiced for the home). total_invoice can be a partial /
    # net-of-fees figure on some invoices, so gross is the safer cost proxy; fall back to
    # total_invoice only when gross is blank.
    basis = gross_invoice.to_f.positive? ? gross_invoice.to_f : total_invoice.to_f
    return unless basis.positive?

    # update_column: skip validations/callbacks (avoids touching the vehicle's own
    # normalize/discount callbacks on an invoice save) and don't recurse. Seeds the
    # dealer_cost (Home Cost) field specifically so it shows in Cost Details and flows to GP.
    v.update_column(:dealer_cost, basis.round(2))
  end

  def scanned_document_is_internal_and_owned
    doc = scanned_document
    if doc.nil?
      errors.add(:scanned_document_id, 'not found')
    elsif doc.vehicle_id != vehicle_id
      errors.add(:scanned_document_id, 'must belong to this vehicle')
    elsif doc.visibility != 'internal'
      errors.add(:scanned_document_id, 'must be an internal-only document')
    end
  end
end
