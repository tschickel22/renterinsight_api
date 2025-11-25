# frozen_string_literal: true

# Polymorphic settings table for storing various configuration options
# Can be scoped to different models (Company, User, etc.) or platform-level (scope_id: nil)
class Setting < ApplicationRecord
  # Validations
  validates :scope_type, presence: true
  validates :key, presence: true
  validates :key, uniqueness: { scope: [:scope_type, :scope_id] }
  
  # scope_id is required for non-platform settings, but can be nil for platform
  validates :scope_id, presence: true, unless: -> { scope_type == 'platform' }
  
  # Scopes
  scope :for_scope, ->(scope_type, scope_id) { where(scope_type: scope_type, scope_id: scope_id) }
  scope :with_key, ->(key) { where(key: key) }
  scope :platform_settings, -> { where(scope_type: 'platform', scope_id: nil) }
  scope :company_settings, ->(company_id) { where(scope_type: 'company', scope_id: company_id) }
  
  # Helper method to get a setting value
  def self.get(scope_type, scope_id, key, default = nil)
    setting = find_by(scope_type: scope_type, scope_id: scope_id, key: key)
    return default unless setting
    
    begin
      JSON.parse(setting.value)
    rescue JSON::ParserError
      setting.value
    end
  end
  
  # Helper method to set a setting value
  def self.set(scope_type, scope_id, key, value)
    setting = find_or_initialize_by(
      scope_type: scope_type,
      scope_id: scope_id,
      key: key
    )
    setting.value = value.is_a?(String) ? value : value.to_json
    setting.save!
  end
  
  # Get setting with fallback: Company → Platform → Default
  # This implements the hierarchy: Company overrides → Platform defaults → Provided default
  #
  # @param key [String] The setting key to look up
  # @param company_id [Integer, nil] Optional company ID to check for company-specific override
  # @param default [Any] Default value if setting not found anywhere
  # @return [Any] The setting value from company, platform, or default
  #
  # Example:
  #   Setting.get_with_fallback('payment_processor', company.id, 'manual')
  #   # Checks: company.id → platform → 'manual'
  #
  def self.get_with_fallback(key, company_id = nil, default = nil)
    # First, try company-specific setting if company_id provided
    if company_id.present?
      company_value = get('company', company_id, key)
      return company_value if company_value.present?
    end
    
    # Fall back to platform-level setting
    platform_value = get('platform', nil, key)
    return platform_value if platform_value.present?
    
    # Finally, return provided default
    default
  end
  
  # Bulk get multiple settings with fallback
  # Returns a hash of key => value
  #
  # @param keys [Array<String>] Array of setting keys to fetch
  # @param company_id [Integer, nil] Optional company ID for overrides
  # @return [Hash] Hash of key => value pairs
  #
  # Example:
  #   settings = Setting.get_multiple_with_fallback(
  #     ['payment_processor', 'zego_gateway_id'],
  #     company.id
  #   )
  #   # => { 'payment_processor' => 'zego', 'zego_gateway_id' => '12345' }
  #
  def self.get_multiple_with_fallback(keys, company_id = nil)
    keys.each_with_object({}) do |key, result|
      result[key] = get_with_fallback(key, company_id)
    end
  end
  
  # Check if a setting exists at any level
  #
  # @param key [String] The setting key to check
  # @param company_id [Integer, nil] Optional company ID
  # @return [Boolean] True if setting exists at company or platform level
  #
  def self.exists_at_any_level?(key, company_id = nil)
    return true if company_id.present? && exists?(scope_type: 'company', scope_id: company_id, key: key)
    exists?(scope_type: 'platform', scope_id: nil, key: key)
  end
  
  # Get all settings for a scope as a hash
  #
  # @param scope_type [String] The scope type ('platform', 'company', etc.)
  # @param scope_id [Integer, nil] The scope ID
  # @return [Hash] Hash of all settings for the scope
  #
  def self.all_for_scope(scope_type, scope_id = nil)
    for_scope(scope_type, scope_id).each_with_object({}) do |setting, hash|
      begin
        hash[setting.key] = JSON.parse(setting.value)
      rescue JSON::ParserError
        hash[setting.key] = setting.value
      end
    end
  end
  
  # Delete a setting
  #
  # @param scope_type [String] The scope type
  # @param scope_id [Integer, nil] The scope ID
  # @param key [String] The setting key
  # @return [Boolean] True if deleted, false if not found
  #
  def self.delete_setting(scope_type, scope_id, key)
    setting = find_by(scope_type: scope_type, scope_id: scope_id, key: key)
    return false unless setting
    
    setting.destroy
    true
  end
end
