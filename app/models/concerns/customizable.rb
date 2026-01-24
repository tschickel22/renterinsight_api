# frozen_string_literal: true

module Customizable
  extend ActiveSupport::Concern
  
  included do
    # Ensure custom_fields column exists and is initialized
    after_initialize :initialize_custom_fields
    before_validation :validate_custom_fields
    before_save :apply_custom_field_validations
  end
  
  class_methods do
    def custom_field_definitions
      CustomField.active.for_module(name.underscore.pluralize).ordered
    end
    
    def custom_fields_for_role(role_key)
      custom_field_definitions.select { |cf| cf.visible_to_role?(role_key) }
    end
  end
  
  # Instance methods
  def get_custom_field(field_key)
    custom_fields&.dig(field_key.to_s)
  end
  
  def set_custom_field(field_key, value)
    self.custom_fields ||= {}
    self.custom_fields[field_key.to_s] = value
  end
  
  def custom_field_definitions
    module_name = self.class.name.underscore.pluralize
    query = CustomField.active.for_module(module_name).ordered
    
    # Filter by company if model has company_id
    if respond_to?(:company_id) && company_id.present?
      query = query.where(company_id: company_id)
    end
    
    query
  end
  
  def custom_fields_for_role(role_key)
    custom_field_definitions.select { |cf| cf.visible_to_role?(role_key) }
  end
  
  def apply_custom_fields_from_params(custom_fields_params)
    return unless custom_fields_params.is_a?(Hash)
    
    valid_keys = custom_field_definitions.map(&:field_key)
    
    custom_fields_params.each do |key, value|
      next unless valid_keys.include?(key.to_s)
      set_custom_field(key, value)
    end
  end
  
  def custom_fields_with_metadata
    definitions = custom_field_definitions.index_by(&:field_key)
    
    (custom_fields || {}).map do |key, value|
      definition = definitions[key]
      {
        field_key: key,
        value: value,
        definition: definition&.as_json(only: [:id, :name, :field_type, :label, :required, :options])
      }
    end
  end
  
  private
  
  def initialize_custom_fields
    self.custom_fields ||= {}
  end
  
  def validate_custom_fields
    return true unless custom_fields.present?
    
    custom_field_definitions.each do |field_def|
      value = get_custom_field(field_def.field_key)
      
      # Validate the value
      field_errors = field_def.validate_value(value)
      
      field_errors.each do |error|
        errors.add(:base, "#{field_def.label}: #{error}")
      end
    end
  end
  
  def apply_custom_field_validations
    # This runs before_save to ensure data is valid
    return true unless errors.any?
    throw(:abort)
  end
end
