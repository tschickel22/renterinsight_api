# frozen_string_literal: true

class SubscriptionPlan < ApplicationRecord
  # Associations
  has_many :subscription_plan_modules, dependent: :destroy
  has_many :tenant_subscriptions, dependent: :restrict_with_error
  
  # Accept nested attributes for modules
  accepts_nested_attributes_for :subscription_plan_modules, allow_destroy: true
  
  # Validations
  validates :name, presence: true, uniqueness: { case_sensitive: false }
  validates :display_name, presence: true
  validates :category, presence: true, inclusion: { in: %w[starter professional enterprise] }
  validates :billing_model, inclusion: { in: %w[flat per_user tiered] }
  validates :discount_type, inclusion: { in: %w[percent amount] }, allow_nil: true
  validates :pricing_monthly, :pricing_annual, numericality: { greater_than_or_equal_to: 0 }
  validates :max_users, :max_storage_gb, :max_locations, :max_api_calls, 
            numericality: { greater_than: 0 }, allow_nil: true
  
  # Scopes
  scope :active, -> { where(is_active: true) }
  scope :ordered, -> { order(position: :asc, created_at: :asc) }
  scope :by_category, ->(cat) { where(category: cat) }
  scope :with_modules, -> { includes(:subscription_plan_modules) }
  
  # Class methods
  class << self
    def starter
      find_by(name: 'starter')
    end
    
    def professional
      find_by(name: 'professional')
    end
    
    def enterprise
      find_by(name: 'enterprise')
    end
    
    def default_plan
      active.ordered.first || professional || starter
    end
  end
  
  # Instance methods
  
  # Trial check helper (explicit for clarity)
  def trial_enabled?
    trial_enabled == true
  end
  
  # Get all enabled module keys for this plan
  def enabled_module_keys
    subscription_plan_modules.where(is_enabled: true).pluck(:module_key)
  end
  
  # Check if a specific module is enabled
  def module_enabled?(module_key)
    subscription_plan_modules.exists?(module_key: module_key, is_enabled: true)
  end
  
  # Enable a module for this plan
  def enable_module!(module_key)
    mod = subscription_plan_modules.find_or_initialize_by(module_key: module_key)
    mod.update!(is_enabled: true)
  end
  
  # Disable a module for this plan
  def disable_module!(module_key)
    subscription_plan_modules.where(module_key: module_key).update_all(is_enabled: false)
  end
  
  # Set modules from a hash { 'crm.prospecting' => true, 'finance.loans' => false }
  def set_modules(module_hash)
    module_hash.each do |key, enabled|
      mod = subscription_plan_modules.find_or_initialize_by(module_key: key)
      mod.is_enabled = enabled
      mod.save!
    end
  end
  
  # Bulk set modules from an array of enabled module keys
  def set_enabled_modules(enabled_keys)
    PlatformModule.all_keys.each do |key|
      mod = subscription_plan_modules.find_or_initialize_by(module_key: key)
      mod.is_enabled = enabled_keys.include?(key)
      mod.save!
    end
  end
  
  # Calculate effective price with discount
  def effective_monthly_price
    apply_discount(pricing_monthly)
  end
  
  def effective_annual_price
    apply_discount(pricing_annual)
  end
  
  def discount_amount(base_price)
    return 0 if discount_type.blank? || discount_value.blank? || discount_value <= 0
    
    case discount_type
    when 'percent'
      (base_price * discount_value / 100).round(2)
    when 'amount'
      [discount_value, base_price].min
    else
      0
    end
  end
  
  # Serialize for API response
  def as_json_with_modules
    {
      id: id,
      name: name,
      display_name: display_name,
      description: description,
      category: category,
      zoho_plan_code: zoho_plan_code,
      pricing: {
        monthly: pricing_monthly.to_f,
        annual: pricing_annual.to_f,
        effective_monthly: effective_monthly_price.to_f,
        effective_annual: effective_annual_price.to_f,
        currency: currency,
        billing_model: billing_model
      },
      limits: {
        max_users: max_users,
        max_storage_gb: max_storage_gb,
        max_locations: max_locations,
        max_api_calls: max_api_calls
      },
      trial: {
        enabled: trial_enabled,
        days: trial_days
      },
      setup_fee: setup_fee.to_f,
      discount: discount_type.present? ? {
        type: discount_type,
        value: discount_value.to_f,
        coupon_code: zoho_coupon_code
      } : nil,
      is_active: is_active,
      is_popular: is_popular,
      position: position,
      modules: modules_hash,
      created_at: created_at,
      updated_at: updated_at
    }
  end
  
  # Get modules as categorized hash for UI
  def modules_hash
    result = {}
    subscription_plan_modules.each do |mod|
      result[mod.module_key] = mod.is_enabled
    end
    result
  end
  
  private
  
  def apply_discount(base_price)
    base_price - discount_amount(base_price)
  end
end
