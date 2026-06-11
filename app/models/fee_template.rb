# frozen_string_literal: true

# Reusable Deal Desk fee (doc / title / license / prep / delivery / setup).
# @company-scoped. Seeded samples are flagged is_seeded: true.
class FeeTemplate < ApplicationRecord
  FEE_TYPES   = %w[doc title license prep delivery setup other].freeze
  APPLIES_TO  = %w[rv manufactured_home all].freeze

  belongs_to :company

  validates :name, presence: true
  validates :fee_type, inclusion: { in: FEE_TYPES }
  validates :applies_to, inclusion: { in: APPLIES_TO }
  validates :default_amount, numericality: { greater_than_or_equal_to: 0 }

  scope :active, -> { where(active: true) }
  scope :seeded, -> { where(is_seeded: true) }
  scope :for_collateral, ->(type) { where(applies_to: [type, 'all']) }
  scope :ordered, -> { order(:position, :name) }
end
