# frozen_string_literal: true

class CommissionComponent < ApplicationRecord
  belongs_to :company
  belongs_to :location, optional: true
  belongs_to :commission_plan, optional: true
  
  # Component Types
  COMPONENT_TYPES = %w[
    percent_of_gross
    flat_per_unit
    volume_bonus
    addon_commission
  ].freeze
  
  # Gross Types (for percent_of_gross)
  GROSS_TYPES = %w[
    front
    back
    total
    commissionable_front
    addon
    house_profit
    plan_basis
  ].freeze

  # How each figure reads to a person. plan_basis is "what this plan pays on",
  # the checklist on the plan (CommissionPlan#pays_on).
  GROSS_LABELS = {
    'front' => 'front gross', 'back' => 'back-end gross', 'total' => 'total gross',
    'commissionable_front' => 'commissionable gross (after pack)', 'addon' => 'add-on sales',
    'house_profit' => 'house profit (the home only)', 'plan_basis' => 'what this plan pays on'
  }.freeze

  def self.gross_label(type)
    GROSS_LABELS[type.to_s] || type.to_s.humanize.downcase
  end
  
  # Roles (applies_to_role values)
  ROLES = %w[
    primary_salesperson
    secondary_salesperson
    sales_manager
    finance_manager
    desk_manager
    all_participants
  ].freeze
  
  # Deal Types
  DEAL_TYPES = %w[new used all].freeze
  
  # Verticals
  VERTICALS = %w[rv mh all].freeze
  
  # Threshold Periods
  THRESHOLD_PERIODS = %w[monthly quarterly].freeze
  
  # ============================================================================
  # VALIDATIONS
  # ============================================================================
  
  validates :name, presence: true, length: { maximum: 255 }
  validates :component_type, presence: true, inclusion: { in: COMPONENT_TYPES }
  # TEMPORARY: Allow nil for backward compatibility with existing data
  # After running data migration, change to: validates :applies_to_role, presence: true, inclusion: { in: ROLES }
  validates :applies_to_role, inclusion: { in: ROLES, allow_nil: true }  # TODO: Remove allow_nil after data migration
  validates :deal_type, inclusion: { in: DEAL_TYPES, allow_nil: true }
  validates :vertical, inclusion: { in: VERTICALS, allow_nil: true }
  
  # Type-specific validations
  validates :gross_type, 
    presence: true,
    inclusion: { in: GROSS_TYPES },
    if: -> { component_type == 'percent_of_gross' }
  
  validates :rate, 
    presence: true,
    numericality: { greater_than: 0, less_than_or_equal_to: 1 },
    if: -> { component_type.in?(%w[percent_of_gross addon_commission]) }
  
  validates :flat_amount,
    presence: true,
    numericality: { greater_than: 0 },
    if: -> { component_type.in?(%w[flat_per_unit volume_bonus]) }
  
  validates :min_amount, numericality: { greater_than_or_equal_to: 0 }, allow_nil: true
  validates :max_amount, numericality: { greater_than: 0 }, allow_nil: true
  validate :min_not_over_max
  validate :tiers_make_sense

  validates :units_threshold,
    presence: true,
    numericality: { greater_than: 0, only_integer: true },
    if: -> { component_type == 'volume_bonus' }
  
  validates :threshold_period,
    presence: true,
    inclusion: { in: THRESHOLD_PERIODS },
    if: -> { component_type == 'volume_bonus' }
  
  # ============================================================================
  # SCOPES
  # ============================================================================
  
  scope :active, -> { where(is_active: true) }
  scope :inactive, -> { where(is_active: false) }
  scope :for_role, ->(role) { where('applies_to_role IS NULL OR applies_to_role = ?', role) }
  scope :for_location, ->(location_id) { where('location_id IS NULL OR location_id = ?', location_id) }
  scope :company_wide, -> { where(location_id: nil) }
  scope :location_specific, -> { where.not(location_id: nil) }
  scope :ordered, -> { order(:sequence, :id) }

# Location filtering scope (matches standard pattern)
scope :for_current_location, -> {
  Current.location_filtered? ? where(location_id: Current.location_id) : all
}

  
  # ============================================================================
  # INSTANCE METHODS
  # ============================================================================
  
  # Whether this component pays on the deal. A deal's new/used and MH/RV come
  # from Deal#commission_deal_type and #commission_vertical (deal_type on a
  # real deal usually holds the financing type, like Chattel or FHA). When the
  # deal's kind is unknown, only components meant for all deals apply.
  def applies_to_deal?(deal)
    return false if deal_type.present? && deal_type != 'all' && deal_type != deal.try(:commission_deal_type)
    return false if vertical.present? && vertical != 'all' && vertical != deal.try(:commission_vertical)

    true
  end

  # True once a commission payment has paid this component, which is when it
  # can no longer be taken off its plan. Payments record their components in
  # calculation_details line_items (component_id since the engine rework;
  # older payments only by name, so those are matched by plan and name).
  def paid?
    payments = CommissionPayment.where(company_id: company_id, is_deleted: [false, nil])
    return true if payments.where("calculation_details -> 'line_items' @> ?", [{ component_id: id }].to_json).exists?
    return false unless commission_plan_id

    payments.where("commission_plan_id = :plan OR calculation_details ->> 'plan_id' = :plan_s", plan: commission_plan_id, plan_s: commission_plan_id.to_s)
            .where("calculation_details -> 'line_items' @> ?", [{ description: name }].to_json).exists?
  end

  # Human-readable description of what this component pays
  def calculation_description
    case component_type
    when 'percent_of_gross'
      base = tiered? ? "#{tier_description} of #{self.class.gross_label(gross_type)}" : "#{(rate * 100).round(2)}% of #{self.class.gross_label(gross_type)}"
      [base, limits_description].compact.join(', ')
    when 'flat_per_unit'
      "#{money(flat_amount)} per unit (times the deal's quantity)"
    when 'volume_bonus'
      "#{money(flat_amount)} bonus once per #{threshold_period == 'quarterly' ? 'quarter' : 'month'}, on the #{units_threshold.to_i.ordinalize} unit"
    when 'addon_commission'
      "#{(rate * 100).round(2)}% of add-ons (delivery, setup, etc.)"
    else
      component_type.humanize
    end
  end
  
  # Pays by gross bands: [{ 'up_to' => 10000, 'rate' => 0.2 }, { 'rate' => 0.25 }],
  # each band's rate on the part of the gross inside it (like tax brackets).
  def tiered?
    component_type.in?(%w[percent_of_gross addon_commission]) && normalized_tiers.any?
  end

  def normalized_tiers
    Array(tiers).filter_map do |t|
      t = t.to_h.stringify_keys
      next if t['rate'].blank?

      { 'up_to' => t['up_to'].presence&.to_d, 'rate' => t['rate'].to_d }
    end
  end

  # rate x base, or band by band when tiered. Nothing on a base of zero or less.
  def percent_amount(base)
    base = base.to_d
    return BigDecimal('0') if base <= 0
    return base * rate.to_d unless tiered?

    floor = BigDecimal('0')
    normalized_tiers.sum(BigDecimal('0')) do |t|
      top = t['up_to'] || base
      part = [[base, top].min - floor, BigDecimal('0')].max
      floor = [floor, top].max
      part * t['rate']
    end
  end

  # The per-deal floor and ceiling: [amount, note]. The note says when one applied.
  def limit(amount)
    amount = amount.to_d
    if min_amount.present? && amount < min_amount.to_d
      [min_amount.to_d, "at least #{money(min_amount)} per deal"]
    elsif max_amount.present? && amount > max_amount.to_d
      [max_amount.to_d, "at most #{money(max_amount)} per deal"]
    else
      [amount, nil]
    end
  end

  def tier_description
    floor = BigDecimal('0')
    normalized_tiers.map do |t|
      pct = "#{(t['rate'] * 100).round(2).to_s('F').sub(/\.0\z/, '')}%"
      text = t['up_to'] ? "#{pct} up to #{money(t['up_to'])}" : (floor.positive? ? "#{pct} above #{money(floor)}" : pct)
      floor = t['up_to'] if t['up_to']
      text
    end.join(', ')
  end

  def limits_description
    parts = []
    parts << "at least #{money(min_amount)}" if min_amount.present?
    parts << "at most #{money(max_amount)}" if max_amount.present?
    parts.any? ? "#{parts.join(' and ')} per deal" : nil
  end

  # Display name with context
  def display_name
    context = []
    context << location.name if location.present?
    context << applies_to_role.humanize if applies_to_role.present?
    context << deal_type.upcase if deal_type.present? && deal_type != 'all'
    context << vertical.upcase if vertical.present? && vertical != 'all'
    
    parts = [name]
    parts << "(#{context.join(', ')})" if context.any?
    parts.join(' ')
  end
  
  # Scope level (company-wide or location-specific)
  def scope_level
    location_id.present? ? 'location' : 'company'
  end

  private

  def min_not_over_max
    return unless min_amount.present? && max_amount.present? && min_amount.to_d > max_amount.to_d

    errors.add(:base, 'The most per deal must be at least the least per deal')
  end

  # Bands go up in order, every band but the last has a top, rates are 0 to 100%.
  def tiers_make_sense
    list = Array(tiers)
    return if list.empty?

    bands = normalized_tiers
    errors.add(:tiers, 'each band needs a rate') and return if bands.size != list.size
    errors.add(:tiers, 'rates must be more than 0% and at most 100%') if bands.any? { |t| t['rate'] <= 0 || t['rate'] > 1 }
    tops = bands[0...-1].map { |t| t['up_to'] }
    errors.add(:tiers, 'every band but the last needs an "up to" amount') if tops.any?(&:nil?)
    errors.add(:tiers, 'bands must go up in order') if tops.compact.each_cons(2).any? { |a, b| b <= a }
  end

  def money(amount)
    ActiveSupport::NumberHelper.number_to_currency(amount)
  end
end
