# frozen_string_literal: true

# Service for checking module access for a company/tenant
# Handles the logic of plan-based access + per-tenant overrides
class ModuleAccessService
  attr_reader :company
  
  def initialize(company)
    @company = company
    @cache = {}
  end
  
  # Check if a company has access to a specific module
  def has_module?(module_key)
    return false unless PlatformModule.valid_key?(module_key)
    
    # Use cached result if available
    return @cache[module_key] if @cache.key?(module_key)
    
    # Check override first (takes precedence)
    override = company.tenant_module_overrides.find_by(module_key: module_key)
    if override.present?
      @cache[module_key] = override.is_enabled
      return override.is_enabled
    end
    
    # Fall back to subscription plan
    subscription = company.tenant_subscription
    unless subscription&.subscription_plan
      # No subscription - check legacy subscription_tier field
      @cache[module_key] = legacy_tier_check(module_key)
      return @cache[module_key]
    end
    
    # Check plan modules
    enabled = subscription.subscription_plan
                         .subscription_plan_modules
                         .exists?(module_key: module_key, is_enabled: true)
    
    @cache[module_key] = enabled
    enabled
  end
  
  # Alias for has_module?
  def module_enabled?(module_key)
    has_module?(module_key)
  end
  
  # Get module configuration (merged: plan defaults → overrides)
  # Returns hash like { "marketing.website" => { "website_access_level" => 3 } }
  def module_configs
    configs = {}

    # 1. Start with plan-level configs
    subscription = company.tenant_subscription
    if subscription&.subscription_plan
      subscription.subscription_plan
                  .subscription_plan_modules
                  .where(is_enabled: true)
                  .where.not(config: [nil, {}])
                  .each do |spm|
        configs[spm.module_key] = (spm.config || {}).deep_stringify_keys
      end
    else
      # Legacy fallback: use default configs from PlatformModule
      tier = company.subscription_tier&.to_sym || :starter
      PlatformModule.default_configs_for_template(tier).each do |key, cfg|
        configs[key] = cfg.deep_stringify_keys
      end
    end

    # 2. Merge company-level overrides (takes precedence)
    company.tenant_module_overrides
           .where.not(config: [nil, {}])
           .each do |override|
      configs[override.module_key] ||= {}
      configs[override.module_key].merge!((override.config || {}).deep_stringify_keys)
    end

    configs
  end

  # Get config for a specific module
  def module_config(module_key)
    module_configs[module_key] || {}
  end

  # Get all enabled modules for the company
  def enabled_modules
    # Start with plan modules
    plan_modules = plan_enabled_modules
    
    Rails.logger.info "[ModuleAccessService] Company: #{company.id} - enabled_modules check"
    Rails.logger.info "[ModuleAccessService] Has tenant_subscription: #{company.tenant_subscription.present?}"
    Rails.logger.info "[ModuleAccessService] Has subscription_plan: #{company.tenant_subscription&.subscription_plan.present?}"
    Rails.logger.info "[ModuleAccessService] Plan modules from DB: #{plan_modules.inspect}"
    
    # Apply overrides
    company.tenant_module_overrides.each do |override|
      if override.is_enabled
        plan_modules << override.module_key unless plan_modules.include?(override.module_key)
      else
        plan_modules.delete(override.module_key)
      end
    end
    
    Rails.logger.info "[ModuleAccessService] Final enabled modules: #{plan_modules.uniq.inspect}"
    plan_modules.uniq
  end
  
  # Get all disabled modules for the company
  def disabled_modules
    PlatformModule.all_keys - enabled_modules
  end
  
  # Get modules with their access status and source
  def modules_with_status
    result = {}
    
    plan_modules = plan_modules_hash
    overrides = company.tenant_module_overrides.index_by(&:module_key)
    
    PlatformModule.all_keys.each do |key|
      override = overrides[key]
      
      if override.present?
        result[key] = {
          enabled: override.is_enabled,
          source: 'override',
          reason: override.override_reason,
          overridden_at: override.updated_at
        }
      else
        result[key] = {
          enabled: plan_modules[key] || false,
          source: 'plan'
        }
      end
    end
    
    result
  end
  
  # Get modules grouped by category with status
  def modules_by_category
    modules_status = modules_with_status
    
    PlatformModule.categories_with_modules.map do |category|
      {
        name: category[:name],
        icon: category[:icon],
        description: category[:description],
        modules: category[:modules].map do |mod|
          status = modules_status[mod[:key]] || { enabled: false, source: 'none' }
          mod.merge(
            enabled: status[:enabled],
            source: status[:source],
            override_reason: status[:reason]
          )
        end
      }
    end
  end
  
  # Check if company can use the platform (has active subscription)
  def can_access_platform?
    subscription = company.tenant_subscription
    return legacy_access_check unless subscription
    
    subscription.usable?
  end
  
  # Get subscription status info
  def subscription_status
    subscription = company.tenant_subscription
    
    return legacy_subscription_status unless subscription
    
    {
      has_subscription: true,
      plan_name: subscription.plan_name,
      plan_display_name: subscription.plan_display_name,
      status: subscription.status,
      is_active: subscription.active?,
      is_trial: subscription.trial?,
      trial_days_remaining: subscription.trial_days_remaining,
      in_grace_period: subscription.in_grace_period?,
      grace_days_remaining: subscription.grace_period_days_remaining,
      current_period_end: subscription.current_period_end,
      limits: {
        max_users: subscription.max_users,
        max_storage_gb: subscription.max_storage_gb,
        max_locations: subscription.max_locations,
        current_users: subscription.current_users,
        current_storage_gb: subscription.current_storage_gb,
        current_locations: subscription.current_locations
      }
    }
  end
  
  # Full access report for API
  def as_json
    {
      company_id: company.id,
      subscription: subscription_status,
      modules: modules_with_status,
      modules_by_category: modules_by_category,
      enabled_module_keys: enabled_modules,
      disabled_module_keys: disabled_modules,
      module_configs: module_configs
    }
  end
  
  # Set an override for a module
  def set_override!(module_key, enabled, reason: nil, user: nil)
    return false unless PlatformModule.valid_key?(module_key)
    
    override = company.tenant_module_overrides.find_or_initialize_by(module_key: module_key)
    override.is_enabled = enabled
    override.override_reason = reason if reason.present?
    override.overridden_by = user if user.present?
    override.save!
    
    # Clear cache
    @cache.delete(module_key)
    
    true
  end
  
  # Remove an override (revert to plan default)
  def remove_override!(module_key)
    company.tenant_module_overrides.where(module_key: module_key).destroy_all
    @cache.delete(module_key)
    true
  end
  
  # Bulk set overrides
  def set_overrides!(overrides_hash, reason: nil, user: nil)
    overrides_hash.each do |key, enabled|
      set_override!(key, enabled, reason: reason, user: user)
    end
  end
  
  private
  
  def plan_enabled_modules
    subscription = company.tenant_subscription
    
    if subscription&.subscription_plan
      Rails.logger.info "[ModuleAccessService] Using subscription_plan_modules for company #{company.id}"
      return subscription.subscription_plan
                        .subscription_plan_modules
                        .where(is_enabled: true)
                        .pluck(:module_key)
    else
      Rails.logger.warn "[ModuleAccessService] No subscription_plan found for company #{company.id}, using legacy fallback"
      return legacy_enabled_modules
    end
  end
  
  def plan_modules_hash
    subscription = company.tenant_subscription
    return legacy_modules_hash unless subscription&.subscription_plan
    
    subscription.subscription_plan
               .subscription_plan_modules
               .pluck(:module_key, :is_enabled)
               .to_h
  end
  
  # Legacy support for companies without TenantSubscription
  # Based on subscription_tier field on Company
  def legacy_tier_check(module_key)
    tier = company.subscription_tier&.to_sym || :starter
    PlatformModule.template_modules(tier).include?(module_key)
  end
  
  def legacy_enabled_modules
    tier = company.subscription_tier&.to_sym || :starter
    PlatformModule.template_modules(tier)
  end
  
  def legacy_modules_hash
    PlatformModule.modules_hash_for_template(company.subscription_tier || 'starter')
  end
  
  def legacy_access_check
    # Legacy: allow access if company has any status
    company.status.in?(%w[active trial]) || company.status.nil?
  end
  
  def legacy_subscription_status
    tier = company.subscription_tier || 'starter'
    template_limits = case tier
                      when 'starter' then { max_users: 5, max_storage_gb: 10, max_locations: 1 }
                      when 'professional' then { max_users: 25, max_storage_gb: 100, max_locations: 5 }
                      when 'enterprise' then { max_users: nil, max_storage_gb: nil, max_locations: nil }
                      else { max_users: 5, max_storage_gb: 10, max_locations: 1 }
                      end
    
    {
      has_subscription: false,
      plan_name: tier,
      plan_display_name: tier.titleize,
      status: company.status || 'active',
      is_active: company.active?,
      is_trial: company.trial?,
      trial_days_remaining: company.trial_ends_at ? [(company.trial_ends_at.to_date - Date.current).to_i, 0].max : 0,
      in_grace_period: false,
      grace_days_remaining: 0,
      current_period_end: nil,
      limits: template_limits.merge(
        current_users: company.users_count,
        current_storage_gb: 0,
        current_locations: company.locations_count
      ),
      legacy_mode: true
    }
  end
end
