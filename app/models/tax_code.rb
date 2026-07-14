# frozen_string_literal: true

# TaxCode is a per-company tax jurisdiction / rate that gets applied to
# taxable invoice line items. Ordered by `position` so compound taxes stack
# in a deterministic sequence — non-compound codes tax the raw line subtotal,
# compound codes tax the running total (subtotal + earlier taxes).
class TaxCode < ApplicationRecord
  belongs_to :company
  belongs_to :chart_of_account, optional: true
  has_many   :invoice_item_taxes, dependent: :restrict_with_error

  validates :name, presence: true, uniqueness: { scope: :company_id, case_sensitive: false }
  validates :rate, presence: true, numericality: { greater_than_or_equal_to: 0 }
  validates :position, numericality: { only_integer: true, greater_than_or_equal_to: 0 }

  scope :active,  -> { where(is_active: true) }
  scope :ordered, -> { order(position: :asc, id: :asc) }
end
