# frozen_string_literal: true

class TenantModuleOverride < ApplicationRecord
  # Associations
  belongs_to :company
  belongs_to :overridden_by, class_name: 'User', optional: true
  
  after_commit :bust_tenant_basic_cache
  after_commit :welcome_ai_connector_admins, on: %i[create update]

  AI_CONNECTOR_KEY = 'admin.ai_connector'

  # Validations
  validates :module_key, presence: true
  validates :module_key, uniqueness: { scope: :company_id }
  validate :valid_module_key
  
  # Scopes
  scope :enabled, -> { where(is_enabled: true) }
  scope :disabled, -> { where(is_enabled: false) }
  scope :for_module, ->(key) { where(module_key: key) }
  scope :recent, -> { order(updated_at: :desc) }
  
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
  
  # Serialize for API
  def as_json_detailed
    {
      id: id,
      company_id: company_id,
      module_key: module_key,
      module_name: module_name,
      module_category: module_category,
      is_enabled: is_enabled,
      override_reason: override_reason,
      overridden_by: overridden_by&.slice(:id, :first_name, :last_name, :email),
      created_at: created_at,
      updated_at: updated_at
    }
  end
  
  private

  def bust_tenant_basic_cache
    Rails.cache.delete_matched("tenant_basic/#{company_id}/*")
  rescue NotImplementedError
    Company.where(id: company_id).update_all(updated_at: Time.current)
  end

  # Turning AI Apps on for a dealership emails its admins how to install the
  # DealerTide plugin in Claude and what to ask. Only on the switch from off
  # to on, so saving the row again (a new reason, say) sends nothing.
  def welcome_ai_connector_admins
    return unless module_key == AI_CONNECTOR_KEY && is_enabled
    return unless previously_new_record? || saved_change_to_is_enabled?

    company.users.active.to_a.select(&:effective_admin?).each do |admin|
      AiConnectorMailer.enabled(company_id, admin.id).deliver_later
    end
  rescue StandardError => e
    Rails.logger.error("[TenantModuleOverride] AI connector welcome email failed for company #{company_id}: #{e.message}")
  end

  def valid_module_key
    unless PlatformModule.valid_key?(module_key)
      errors.add(:module_key, "is not a recognized module: #{module_key}")
    end
  end
end
