# frozen_string_literal: true

# A single line on a CommissionPayment — the per-component breakdown of how a
# salesperson's commission was calculated (basis, method, rate, resulting amount).
#
# The commission_payment_line_items table and its FKs already existed in the schema
# (commission_payment_id -> commission_payments ON DELETE CASCADE, commission_component_id
# -> commission_components ON DELETE NULLIFY), but the model class was never defined —
# leaving CommissionPayment's `has_many :commission_payment_line_items, dependent: :destroy`
# dangling and raising "Missing model class" whenever a payment was destroyed.
class CommissionPaymentLineItem < ApplicationRecord
  belongs_to :commission_payment
  belongs_to :commission_component, optional: true

  validates :description, :calculation_basis, :calculation_method, presence: true
  validates :basis_amount, :calculated_amount, presence: true
end
