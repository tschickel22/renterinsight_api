# frozen_string_literal: true

class QuickbooksFieldMapping < ApplicationRecord
  belongs_to :company
  belongs_to :location, optional: true
  
  # Validations
  validates :entity_type, presence: true
  validates :renter_insight_field, presence: true
  validates :quickbooks_field, presence: true
  validates :mapping_type, inclusion: { in: %w[direct computed conditional] }
  
  # Scopes
  scope :for_entity, ->(entity_type) { where(entity_type: entity_type) }
  scope :enabled, -> { where(enabled: true) }
  scope :by_priority, -> { order(priority: :desc, created_at: :asc) }
  
  # Entity types
  ENTITY_TYPES = %w[inventory customers invoices payments vendors purchases].freeze
  
  # Mapping types
  MAPPING_TYPE_DIRECT = 'direct' # Simple field-to-field mapping
  MAPPING_TYPE_COMPUTED = 'computed' # Requires computation/concatenation
  MAPPING_TYPE_CONDITIONAL = 'conditional' # Conditional logic
  
  # Get transformation logic as hash
  def transformation_hash
    return {} if transformation_logic.blank?
    JSON.parse(transformation_logic).deep_symbolize_keys
  rescue JSON::ParserError
    {}
  end
  
  # Set transformation logic from hash
  def transformation_hash=(value)
    self.transformation_logic = value.to_json
  end
  
  # Check if mapping is for a location or company-wide
  def location_specific?
    location_id.present?
  end
  
  # Apply transformation to value
  def transform_value(value, context = {})
    case mapping_type
    when MAPPING_TYPE_DIRECT
      value
    when MAPPING_TYPE_COMPUTED
      apply_computed_transformation(value, context)
    when MAPPING_TYPE_CONDITIONAL
      apply_conditional_transformation(value, context)
    else
      value
    end
  end
  
  private
  
  def apply_computed_transformation(value, context)
    logic = transformation_hash
    
    case logic[:type]
    when 'concatenate'
      # Concatenate multiple fields
      fields = logic[:fields] || []
      separator = logic[:separator] || ' '
      fields.map { |f| context[f.to_sym] }.compact.join(separator)
    when 'template'
      # Apply template
      template = logic[:template] || ''
      context.reduce(template) do |result, (key, val)|
        result.gsub("{#{key}}", val.to_s)
      end
    when 'format'
      # Apply formatting (date, currency, etc.)
      format_value(value, logic[:format])
    else
      value
    end
  end
  
  def apply_conditional_transformation(value, context)
    logic = transformation_hash
    conditions = logic[:conditions] || []
    
    conditions.each do |condition|
      field = condition[:field]
      operator = condition[:operator]
      test_value = condition[:value]
      result = condition[:result]
      
      if evaluate_condition(context[field.to_sym], operator, test_value)
        return result
      end
    end
    
    logic[:default] || value
  end
  
  def evaluate_condition(actual, operator, expected)
    case operator
    when 'equals' then actual == expected
    when 'not_equals' then actual != expected
    when 'contains' then actual.to_s.include?(expected.to_s)
    when 'greater_than' then actual.to_f > expected.to_f
    when 'less_than' then actual.to_f < expected.to_f
    else false
    end
  end
  
  def format_value(value, format_type)
    case format_type
    when 'currency'
      sprintf('%.2f', value.to_f)
    when 'date'
      Date.parse(value.to_s).strftime('%Y-%m-%d') rescue value
    when 'phone'
      value.to_s.gsub(/\D/, '')
    else
      value
    end
  end
end
