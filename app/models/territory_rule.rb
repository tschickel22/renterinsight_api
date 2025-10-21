class TerritoryRule < ApplicationRecord
  belongs_to :territory
  
  validates :field, presence: true
  validates :operator, presence: true, inclusion: { in: %w[equals not_equals contains starts_with ends_with in] }
  
  scope :active, -> { where(active: true) }
  scope :by_priority, -> { order(priority: :desc) }
  
  OPERATORS = {
    'equals' => ->(field_value, rule_value) { field_value == rule_value },
    'not_equals' => ->(field_value, rule_value) { field_value != rule_value },
    'contains' => ->(field_value, rule_value) { field_value.to_s.include?(rule_value) },
    'starts_with' => ->(field_value, rule_value) { field_value.to_s.start_with?(rule_value) },
    'ends_with' => ->(field_value, rule_value) { field_value.to_s.end_with?(rule_value) },
    'in' => ->(field_value, rule_value) { rule_value.split(',').map(&:strip).include?(field_value.to_s) }
  }.freeze
  
  def matches?(account)
    return true unless active
    
    field_value = account.send(field) rescue nil
    return false if field_value.nil?
    
    operator_proc = OPERATORS[operator]
    return false unless operator_proc
    
    operator_proc.call(field_value, value)
  end
end
