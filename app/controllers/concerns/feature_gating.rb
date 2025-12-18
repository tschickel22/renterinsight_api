# frozen_string_literal: true

# FeatureGating concern - Provides module-based access control for controllers
#
# Usage in controllers:
#   class Api::V1::VehiclesController < ApplicationController
#     include FeatureGating
#     
#     # Gate entire controller
#     require_module! 'inventory.vehicles'
#     
#     # Or gate specific actions
#     require_module! 'inventory.vehicles', only: [:index, :show]
#     require_module! 'inventory.vehicles', except: [:index]
#     
#     # Or check in actions manually
#     def create
#       return unless require_module('inventory.vehicles')
#       # ... rest of action
#     end
#   end

module FeatureGating
  extend ActiveSupport::Concern

  included do
    class_attribute :module_requirements, default: []
  end

  class_methods do
    # Declare module requirements for this controller
    # @param module_key [String] The module key to require (e.g., 'inventory.vehicles')
    # @param options [Hash] Options hash with :only or :except action filters
    def require_module!(module_key, options = {})
      self.module_requirements = module_requirements + [{ key: module_key, options: options }]
      
      before_action(options) do
        enforce_module_access!(module_key)
      end
    end
  end

  # Check if current company has access to a module
  # @param module_key [String] The module key to check
  # @return [Boolean] true if access granted
  def has_module?(module_key)
    return true if current_user&.platform_admin?
    return true unless @company.present?
    
    @company.has_module?(module_key)
  end

  # Check module access and render error if denied (for use in actions)
  # @param module_key [String] The module key to check
  # @return [Boolean] true if access granted, false if denied (and error rendered)
  def require_module(module_key)
    unless has_module?(module_key)
      render_module_denied(module_key)
      return false
    end
    true
  end

  # Enforce module access - raises/renders error if access denied
  # @param module_key [String] The module key to check
  def enforce_module_access!(module_key)
    return if has_module?(module_key)
    
    render_module_denied(module_key)
  end

  # Check if company subscription is active/valid
  # @return [Boolean] true if subscription allows platform access
  def subscription_active?
    return true if current_user&.platform_admin?
    return true unless @company.present?
    
    @company.module_access.can_access_platform?
  end

  # Enforce active subscription - call in before_action if needed
  def require_active_subscription!
    return if subscription_active?
    
    render json: {
      error: 'Subscription required',
      code: 'subscription_required',
      message: 'An active subscription is required to access this feature',
      subscription_status: @company&.module_access&.subscription_status
    }, status: :payment_required # 402
  end

  private

  def render_module_denied(module_key)
    module_info = PlatformModule.find(module_key)
    module_name = module_info&.dig(:name) || module_key

    render json: {
      error: 'Feature not available',
      code: 'module_not_enabled',
      module_key: module_key,
      module_name: module_name,
      message: "The '#{module_name}' feature is not included in your subscription plan",
      upgrade_available: true
    }, status: :forbidden # 403
  end
end
