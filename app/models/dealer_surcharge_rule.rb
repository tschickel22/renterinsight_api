# frozen_string_literal: true

# A surcharge worked out instead of typed home by home. The most specific rule
# wins: one plant over all plants, one section count over any. A home's own
# surcharge on the price list or on a Deal Sheet still beats a rule.
class DealerSurchargeRule < ApplicationRecord
  SECTIONS = %w[any single double triple].freeze
  BASES = %w[per_sq_ft flat].freeze
  # Same line the model filter draws: 18 feet wide or less ships as one section.
  SINGLE_MAX_WIDTH = 18
  DOUBLE_MAX_WIDTH = 36

  belongs_to :company
  belongs_to :manufacturer
  belongs_to :factory, optional: true

  validates :section, inclusion: { in: SECTIONS }
  validates :basis, inclusion: { in: BASES }
  validates :amount, numericality: { greater_than_or_equal_to: 0 }

  scope :active, -> { where(active: true) }

  def self.section_of(variant)
    width = variant.width_ft.to_i
    return nil unless width.positive?
    return 'single' if width <= SINGLE_MAX_WIDTH

    width <= DOUBLE_MAX_WIDTH ? 'double' : 'triple'
  end

  def self.square_feet_of(variant)
    return variant.square_feet if variant.square_feet.to_i.positive?

    variant.width_ft.to_i * variant.length_ft.to_i if variant.width_ft.to_i.positive? && variant.length_ft.to_i.positive?
  end

  def self.best_for(rules, variant, factory_id)
    section = section_of(variant)
    rules.select { |r| (r.factory_id.nil? || r.factory_id == factory_id) && (r.section == 'any' || r.section == section) }
         .max_by { |r| [r.factory_id ? 1 : 0, r.section == 'any' ? 0 : 1] }
  end

  # Dollars for this home; nil when a per square foot rule has no size to work from.
  def amount_for(variant)
    return amount.to_d.round(2) if basis == 'flat'

    feet = self.class.square_feet_of(variant)
    feet && (amount.to_d * feet).round(2)
  end
end
