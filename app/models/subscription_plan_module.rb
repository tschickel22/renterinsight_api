# frozen_string_literal: true

class SubscriptionPlanModule < ApplicationRecord
  # Associations
  belongs_to :subscription_plan
  
  # Validations
  validates :module_key, presence: true
  validates :module_key, uniqueness: { scope: :subscription_plan_id }
  validate :valid_module_key
  
  # Scopes
  scope :enabled, -> { where(is_enabled: true) }
  scope :disabled, -> { where(is_enabled: false) }
  scope :for_module, ->(key) { where(module_key: key) }
  
  # Get module info from PlatformModule registry
  def module_info
    PlatformModule.find(module_key)
  end
  
  def module_name
    module_info&.dig(:name) || module_key.titleize
  end
  
  def module_category
    module_info&.dig(:category) || 'Other'
  end
  
  private
  
  def valid_module_key
    unless PlatformModule.valid_key?(module_key)
      errors.add(:module_key, "is not a recognized module: #{module_key}")
    end
  end
end
