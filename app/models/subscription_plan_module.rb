# frozen_string_literal: true

class SubscriptionPlanModule < ApplicationRecord
  # Associations
  belongs_to :subscription_plan
  
  # Validations
  validates :module_key, presence: true
  validates :module_key, uniqueness: { scope: :subscription_plan_id }
  validate :valid_module_key
  
  after_commit :bust_affected_tenant_caches

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

  def bust_affected_tenant_caches
    company_ids = subscription_plan.tenant_subscriptions.pluck(:company_id)
    company_ids.each do |cid|
      Rails.cache.delete_matched("tenant_basic/#{cid}/*")
    rescue NotImplementedError
      Company.where(id: cid).update_all(updated_at: Time.current)
    end
  end

  def valid_module_key
    unless PlatformModule.valid_key?(module_key)
      errors.add(:module_key, "is not a recognized module: #{module_key}")
    end
  end
end
