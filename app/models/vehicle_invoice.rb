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
    sales_allowance hud_fees state_assoc_fees tax_from_invoice ac_from_invoice
    total_invoice nada_base trim_out
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

  # NOTE: Home Cost (vehicle.dealer_cost) is seeded from this invoice by the controller
  # (Api::V1::VehicleInvoicesController#seed_home_cost_from_invoice) on every successful
  # save — NOT by a model after_save. ActiveRecord skips after_save on a no-op (unchanged)
  # save, so a model callback misses re-saves; the controller path is the reliable trigger.

  private

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
