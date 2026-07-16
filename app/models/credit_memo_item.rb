# frozen_string_literal: true

class CreditMemoItem < ApplicationRecord
  belongs_to :credit_memo
  belongs_to :itemable, polymorphic: true, optional: true
  has_many   :credit_memo_item_taxes, dependent: :destroy
  has_many   :tax_codes, through: :credit_memo_item_taxes

  validates :description, presence: true
  validates :quantity, numericality: { greater_than: 0 }
  validates :rate,     numericality: { greater_than_or_equal_to: 0 }

  before_validation :calculate_amount

  # Sum from per-tax-code snapshots (matches how the invoice line does it).
  # Zero when the line isn't taxable or has skip_tax, or when the memo's
  # contact is tax-exempt — same rules as InvoiceItem#tax_amount.
  def tax_amount
    return BigDecimal('0') unless taxable? && !skip_tax?
    credit_memo_item_taxes.sum(:computed_amount).round(2)
  end

  # Rebuild snapshots against the company's active TaxCodes in position
  # order — non-compound codes tax the raw line, compound codes tax the
  # running total. Mirrors InvoiceItem#recompute_taxes! so credits and
  # invoices reverse each other with matching per-jurisdiction detail.
  def recompute_taxes!
    credit_memo_item_taxes.destroy_all
    return if credit_memo.nil?
    return unless taxable?
    return if skip_tax?
    return if credit_memo.contact&.tax_exempt?

    codes = credit_memo.company&.tax_codes&.active&.ordered&.to_a || []
    return if codes.empty?

    base_amount = BigDecimal((amount || 0).to_s)
    running     = base_amount

    codes.each do |code|
      taxable_base = code.is_compound? ? running : base_amount
      computed     = (taxable_base * code.rate / 100).round(4)
      credit_memo_item_taxes.create!(
        tax_code:        code,
        taxable_base:    taxable_base,
        computed_rate:   code.rate,
        computed_amount: computed
      )
      running += computed
    end
  end

  private

  def calculate_amount
    self.amount = (quantity || 1) * (rate || 0)
  end
end
