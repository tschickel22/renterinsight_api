class CommissionRule < ApplicationRecord
  belongs_to :company
  has_many :commissions, dependent: :nullify

  TYPES = %w[flat percentage tiered].freeze

  validates :name, presence: true
  validates :rule_type, inclusion: { in: TYPES }
  validates :amount, presence: true, numericality: { greater_than_or_equal_to: 0 }, if: -> { rule_type == 'flat' }
  validates :rate, presence: true, numericality: { greater_than_or_equal_to: 0, less_than_or_equal_to: 1 }, if: -> { rule_type == 'percentage' }
  validates :tiers, presence: true, if: -> { rule_type == 'tiered' }

  scope :active, -> { where(is_active: true) }

  # Calculate commission amount based on deal value
  def calculate(deal_amount)
    return 0 if deal_amount.nil? || deal_amount <= 0

    case rule_type
    when 'flat'
      amount.to_f
    when 'percentage'
      deal_amount * rate.to_f
    when 'tiered'
      calculate_tiered(deal_amount)
    else
      0
    end
  end

  private

  def calculate_tiered(deal_amount)
    tier = tiers.find do |t|
      min = t['min'] || t[:min] || 0
      max = t['max'] || t[:max]
      
      deal_amount >= min && (max.nil? || deal_amount < max)
    end

    if tier
      rate_value = tier['rate'] || tier[:rate] || 0
      deal_amount * rate_value.to_f
    else
      0
    end
  end
end
