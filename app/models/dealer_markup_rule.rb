# frozen_string_literal: true

# How a dealer marks up factory cost. The most specific matching rule wins
# (SCOPE_RANK), and a location rule beats the company-wide one at the same scope.
class DealerMarkupRule < ApplicationRecord
  SCOPE_RANK = { 'all' => 0, 'manufacturer' => 1, 'series' => 2, 'option_group' => 3,
                 'plan' => 4, 'variant' => 5, 'option' => 6 }.freeze
  SCOPE_TYPES = SCOPE_RANK.keys.freeze
  APPLIES_TO = %w[base options base_and_options].freeze
  # percent: 30 means cost + 30%. multiplier: 1.30. flat: dollars added.
  # manual: the retail price itself. sliding: a smaller share as cost rises,
  # with a minimum in dollars (see #apply).
  MARKUP_TYPES = %w[percent multiplier flat manual sliding].freeze
  # A sliding scale prices a whole home, so it cannot be written for one item.
  SLIDING_SCOPES = %w[all manufacturer series].freeze

  belongs_to :company
  belongs_to :location, optional: true
  belongs_to :manufacturer, optional: true

  validates :scope_type, inclusion: { in: SCOPE_TYPES }
  validates :applies_to, inclusion: { in: APPLIES_TO }
  validates :markup_type, inclusion: { in: MARKUP_TYPES }
  validates :value, numericality: true
  validates :value, numericality: { greater_than: 0 }, if: -> { markup_type.in?(%w[multiplier manual]) }
  validate :scope_fields_present
  validate :sliding_settings, if: :sliding?

  before_validation -> { self.value = 0 }, if: :sliding?
  validate :location_belongs_to_company

  scope :active, -> { where(active: true) }

  def rank
    [SCOPE_RANK.fetch(scope_type), location_id ? 1 : 0]
  end

  # Retail from cost. Manual ignores cost.
  def apply(cost)
    cost = cost.to_d
    case markup_type
    when 'percent' then cost * (1 + (value / 100))
    when 'multiplier' then cost * value
    when 'flat' then cost + value
    when 'manual' then value
    when 'sliding' then sliding_retail(cost)
    end
  end

  def sliding? = markup_type == 'sliding'

  private

  # cost x (1 + MAX(minimum / cost, multiplier x cost ^ -curve))
  def sliding_retail(cost)
    return cost unless cost.positive?

    over = sliding_multiplier.to_f * (cost.to_f**(1 - sliding_curve.to_f))
    cost + [minimum_markup.to_d, over.to_d].max
  end

  def sliding_settings
    errors.add(:sliding_multiplier, 'must be more than 0') unless sliding_multiplier.to_d.positive?
    errors.add(:sliding_curve, 'must be between 0 and 1') unless sliding_curve.to_d.between?(0.0001, 0.9999)
    errors.add(:minimum_markup, 'cannot be negative') if minimum_markup.to_d.negative?
    errors.add(:scope_type, 'must be every home, one manufacturer or one series for a sliding scale') unless SLIDING_SCOPES.include?(scope_type)
    errors.add(:applies_to, 'must include the home for a sliding scale') if applies_to == 'options'
  end

  def scope_fields_present
    case scope_type
    when 'manufacturer'
      errors.add(:manufacturer_id, 'is required for a manufacturer rule') if manufacturer_id.blank?
    when 'series'
      errors.add(:manufacturer_id, 'is required for a series rule') if manufacturer_id.blank?
      errors.add(:scope_value, 'must name the series') if scope_value.blank?
    when 'plan', 'variant', 'option_group', 'option'
      errors.add(:scope_id, "is required for a #{scope_type} rule") if scope_id.blank?
    end
  end

  def location_belongs_to_company
    return if location.nil? || location.company_id == company_id

    errors.add(:location_id, 'must belong to the same company')
  end
end
