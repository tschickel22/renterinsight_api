# frozen_string_literal: true

class CustomField < ApplicationRecord
  belongs_to :company
  belongs_to :created_by, class_name: 'User', optional: true
  belongs_to :updated_by, class_name: 'User', optional: true
  
  has_many :custom_field_permissions, dependent: :destroy
  has_many :roles, through: :custom_field_permissions
  
  # Validations
  validates :name, presence: true
  validates :field_key, presence: true
  validates :field_type, presence: true
  validates :module, presence: true
  validates :field_key, uniqueness: { scope: [:company_id, :module] }
  
  # All supported field types (enterprise-ready)
  FIELD_TYPES = %w[
    text
    number
    currency
    percent
    email
    phone
    url
    longtext
    date
    datetime
    select
    multiselect
    checkbox
    user
    file
  ].freeze
  
  validates :field_type, inclusion: { in: FIELD_TYPES }
  
  # Validate that select/multiselect have options
  validate :select_fields_have_options
  
  # Scopes
  scope :active, -> { where(is_active: true) }
  scope :ordered, -> { order(:section, :display_order, :created_at) }
  scope :for_module, ->(module_name) { where(module: module_name) }
  scope :required_fields, -> { where(required: true) }
  scope :by_section, ->(section_name) { where(section: section_name) }
  scope :user_defined, -> { where(is_system_field: false) }
  scope :system_fields, -> { where(is_system_field: true) }
  
  # Callbacks
  before_validation :generate_field_key, on: :create
  before_validation :normalize_options
  
  # Serialize JSON columns
  serialize :options, coder: JSON
  serialize :validation_rules, coder: JSON
  
  # Helper: Validate a value against this field's rules
  def validate_value(value)
    errors = []
    
    # Required check
    if required && value.blank?
      errors << "#{name} is required"
      return errors
    end
    
    return errors if value.blank? # Skip other validations if empty and not required
    
    # Type-specific validation
    case field_type
    when 'number', 'currency', 'percent'
      errors << "#{name} must be a number" unless value.to_s =~ /^-?\d+\.?\d*$/
      
      if validation_rules.present?
        num_value = value.to_f
        errors << "#{name} must be at least #{validation_rules['min']}" if validation_rules['min'] && num_value < validation_rules['min'].to_f
        errors << "#{name} must be at most #{validation_rules['max']}" if validation_rules['max'] && num_value > validation_rules['max'].to_f
      end
      
    when 'email'
      errors << "#{name} must be a valid email" unless value =~ URI::MailTo::EMAIL_REGEXP
      
    when 'phone'
      errors << "#{name} must be a valid phone number" unless value.to_s.gsub(/\D/, '').length >= 10
      
    when 'url'
      begin
        uri = URI.parse(value)
        errors << "#{name} must be a valid URL" unless uri.is_a?(URI::HTTP) || uri.is_a?(URI::HTTPS)
      rescue URI::InvalidURIError
        errors << "#{name} must be a valid URL"
      end
      
    when 'select'
      errors << "#{name} must be one of: #{options.join(', ')}" unless options&.include?(value)
      
    when 'multiselect'
      value_array = value.is_a?(Array) ? value : JSON.parse(value)
      invalid_options = value_array - (options || [])
      errors << "#{name} contains invalid options: #{invalid_options.join(', ')}" if invalid_options.any?
      
    when 'text', 'longtext'
      if validation_rules.present?
        errors << "#{name} is too short (minimum #{validation_rules['min_length']} characters)" if validation_rules['min_length'] && value.length < validation_rules['min_length'].to_i
        errors << "#{name} is too long (maximum #{validation_rules['max_length']} characters)" if validation_rules['max_length'] && value.length > validation_rules['max_length'].to_i
        errors << "#{name} format is invalid" if validation_rules['pattern'] && value !~ Regexp.new(validation_rules['pattern'])
      end
    end
    
    errors
  end
  
  # Helper: Check if user's role has permission to see this field
  def visible_to_role?(role_key)
    return true if custom_field_permissions.none? # No restrictions = visible to all
    
    permission = custom_field_permissions.joins(:role).find_by(roles: { key: role_key })
    return true if permission.nil? # No explicit permission = visible
    
    permission.permission_level != 'hidden'
  end
  
  # Helper: Check if user's role can edit this field
  def editable_by_role?(role_key)
    return true if custom_field_permissions.none?
    
    permission = custom_field_permissions.joins(:role).find_by(roles: { key: role_key })
    return true if permission.nil?
    
    permission.permission_level == 'write'
  end
  
  def as_json(options = {})
    super(options.merge(
      only: [:id, :module, :name, :field_key, :field_type, :required, :default_value, :display_order, :section, :description, :placeholder, :is_active],
      methods: [:options, :validation_rules]
    ))
  end
  
  private
  
  def generate_field_key
    return if field_key.present?
    
    # Generate snake_case key from name
    base_key = name.downcase.gsub(/[^a-z0-9]+/, '_').gsub(/^_|_$/, '')
    
    # Ensure uniqueness within module
    key = base_key
    counter = 1
    while CustomField.where(company_id: company_id, module: self.module, field_key: key).exists?
      key = "#{base_key}_#{counter}"
      counter += 1
    end
    
    self.field_key = key
  end
  
  def normalize_options
    # Ensure options is an array for select/multiselect
    if (field_type == 'select' || field_type == 'multiselect') && options.is_a?(String)
      self.options = options.split(',').map(&:strip)
    end
  end
  
  def select_fields_have_options
    if (field_type == 'select' || field_type == 'multiselect') && (options.blank? || !options.is_a?(Array) || options.empty?)
      errors.add(:options, 'must be provided for select/multiselect fields')
    end
  end
end