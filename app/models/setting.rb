# frozen_string_literal: true

# Polymorphic settings table for storing various configuration options
# Can be scoped to different models (Company, User, etc.)
class Setting < ApplicationRecord
  # Validations
  validates :scope_type, presence: true
  validates :scope_id, presence: true
  validates :key, presence: true
  validates :key, uniqueness: { scope: [:scope_type, :scope_id] }
  
  # Scopes
  scope :for_scope, ->(scope_type, scope_id) { where(scope_type: scope_type, scope_id: scope_id) }
  scope :with_key, ->(key) { where(key: key) }
  
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
end
