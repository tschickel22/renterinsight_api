# frozen_string_literal: true

class CashReceiptApplication < ApplicationRecord
  belongs_to :cash_receipt
  belongs_to :invoice

  validates :amount_applied, presence: true, numericality: { greater_than: 0 }
  validate :amount_does_not_exceed_invoice_balance, on: :create

  private

  def amount_does_not_exceed_invoice_balance
    return unless invoice
    if amount_applied.to_d > invoice.amount_due.to_d
      errors.add(:amount_applied, "exceeds invoice balance of #{invoice.amount_due}")
    end
  end
end
