# frozen_string_literal: true

# F&I menu product (service contract, GAP, tire/wheel, paint/fabric).
# default_cost is INTERNAL (feeds dealer back-end gross) — never serialize to customers.
# @company-scoped. Seeded samples are flagged is_seeded: true.
class FniProduct < ApplicationRecord
  PRODUCT_TYPES = %w[service_contract gap tire_wheel paint_fabric other].freeze

  belongs_to :company

  validates :name, presence: true
  validates :product_type, inclusion: { in: PRODUCT_TYPES }
  validates :default_price, :default_cost, numericality: { greater_than_or_equal_to: 0 }

  scope :active, -> { where(active: true) }
  scope :seeded, -> { where(is_seeded: true) }
  scope :ordered, -> { order(:position, :name) }

  # Customer-safe projection — never exposes default_cost.
  def customer_h
    { id: id, name: name, product_type: product_type, price: default_price }
  end
end
