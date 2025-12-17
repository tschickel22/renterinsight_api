# Concern for module-based feature gating in controllers
# Include this in controllers that need module-level access control
#
# Usage:
#   class Api::V1::DealsController < ApplicationController
#     include ModuleGating
#     before_action -> { require_module!('crm.deals') }
#   end
#
module ModuleGating
  extend ActiveSupport::Concern

  included do
    helper_method :module_enabled? if respond_to?(:helper_method)
  end

  # Check if a module is enabled for the current company
  def module_enabled?(module_key)
    return false unless @company || Current.company
    
    company = @company || Current.company
    company.has_module?(module_key)
  end

  # Require a module to be enabled, otherwise return 403
  def require_module!(module_key)
    unless module_enabled?(module_key)
      module_info = PlatformModule.find(module_key)
      module_name = module_info ? module_info[:name] : module_key
      
      render json: { 
        error: "Module not available",
        message: "The #{module_name} module is not included in your subscription plan.",
        module_key: module_key,
        upgrade_required: true
      }, status: :forbidden
      
      return false
    end
    true
  end

  # Check multiple modules - require ALL to be enabled
  def require_all_modules!(*module_keys)
    module_keys.each do |key|
      return false unless require_module!(key)
    end
    true
  end

  # Check multiple modules - require ANY to be enabled
  def require_any_module!(*module_keys)
    if module_keys.any? { |key| module_enabled?(key) }
      return true
    end

    render json: { 
      error: "Module not available",
      message: "This feature requires one of the following modules: #{module_keys.join(', ')}",
      module_keys: module_keys,
      upgrade_required: true
    }, status: :forbidden
    
    false
  end

  # Get current company's module access info (for API responses)
  def current_module_access
    return {} unless @company || Current.company
    
    company = @company || Current.company
    ModuleAccessService.new(company).modules_with_status
  end

  # Get enabled module keys for current company
  def enabled_modules
    return [] unless @company || Current.company
    
    company = @company || Current.company
    ModuleAccessService.new(company).enabled_modules
  end
end
