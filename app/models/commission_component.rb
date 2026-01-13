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
  ].freeze
  
  # Roles
  ROLES = %w[
    salesperson
    manager
    f_and_i
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
  validates :applies_to_role, inclusion: { in: ROLES, allow_nil: true }
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
  
  # Check if this component applies to a given deal
  def applies_to_deal?(deal)
    # Check deal type filter
    return false if deal_type.present? && deal_type != 'all' && deal_type != deal.deal_type
    
    # Check vertical filter
    return false if vertical.present? && vertical != 'all' && vertical != deal.vertical
    
    true
  end
  
  # Human-readable description of what this component pays
  def calculation_description
    case component_type
    when 'percent_of_gross'
      "#{(rate * 100).round(2)}% of #{gross_type.humanize} gross"
    when 'flat_per_unit'
      "$#{flat_amount} per unit"
    when 'volume_bonus'
      "$#{flat_amount} bonus if #{units_threshold}+ units per #{threshold_period}"
    when 'addon_commission'
      "#{(rate * 100).round(2)}% of add-ons (delivery, setup, etc.)"
    else
      component_type.humanize
    end
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
end
