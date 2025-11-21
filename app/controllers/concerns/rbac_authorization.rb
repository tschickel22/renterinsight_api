# frozen_string_literal: true

# RbacAuthorization Concern
#
# Provides declarative RBAC authorization for controllers.
# Integrates with PermissionService and ApplicationController's can?/authorize_action! methods.
#
# Usage:
#   class Api::Crm::LeadsController < ApplicationController
#     include RbacAuthorization
#     rbac_resource :crm,
#       read_actions: [:index, :show],
#       create_actions: [:create],
#       update_actions: [:update],
#       delete_actions: [:destroy]
#   end
#
# The concern automatically adds before_action filters to check RBAC permissions
# based on the action being performed.

module RbacAuthorization
  extend ActiveSupport::Concern

  included do
    class_attribute :rbac_config, default: {}
  end

  class_methods do
    # Declare the RBAC resource and action mappings for this controller
    #
    # @param resource_key [Symbol, String] The resource key (e.g., :crm, :inventory)
    # @param options [Hash] Action mappings
    # @option options [Array<Symbol>] :read_actions Actions that require read permission
    # @option options [Array<Symbol>] :create_actions Actions that require create permission
    # @option options [Array<Symbol>] :update_actions Actions that require update permission
    # @option options [Array<Symbol>] :delete_actions Actions that require delete permission
    # @option options [Array<Symbol>] :manage_actions Actions that require manage permission
    # @option options [Array<Symbol>] :export_actions Actions that require export permission
    def rbac_resource(resource_key, options = {})
      self.rbac_config = {
        resource: resource_key.to_s,
        read_actions: Array(options[:read_actions]).map(&:to_sym),
        create_actions: Array(options[:create_actions]).map(&:to_sym),
        update_actions: Array(options[:update_actions]).map(&:to_sym),
        delete_actions: Array(options[:delete_actions]).map(&:to_sym),
        manage_actions: Array(options[:manage_actions]).map(&:to_sym),
        export_actions: Array(options[:export_actions]).map(&:to_sym)
      }

      # Add before_action to check RBAC permissions
      before_action :check_rbac_authorization
    end
  end

  private

  # Check RBAC authorization based on current action
  def check_rbac_authorization
    return true unless rbac_config[:resource].present?
    
    action_sym = action_name.to_sym
    resource_key = rbac_config[:resource]
    
    # Determine the permission action type based on the controller action
    permission_action = determine_permission_action(action_sym)
    
    # If no permission mapping found, allow (fall through to other authorization)
    return true unless permission_action
    
    # Use the existing authorize_action! method from ApplicationController
    authorize_action!(resource_key, permission_action)
  end

  # Map controller action to permission action
  #
  # @param action_sym [Symbol] The controller action
  # @return [String, nil] The permission action key or nil if not mapped
  def determine_permission_action(action_sym)
    config = rbac_config
    
    if config[:read_actions].include?(action_sym)
      'read'
    elsif config[:create_actions].include?(action_sym)
      'create'
    elsif config[:update_actions].include?(action_sym)
      'update'
    elsif config[:delete_actions].include?(action_sym)
      'delete'
    elsif config[:manage_actions].include?(action_sym)
      'manage'
    elsif config[:export_actions].include?(action_sym)
      'export'
    else
      # Default mappings for common RESTful actions
      case action_sym
      when :index, :show
        'read'
      when :new, :create
        'create'
      when :edit, :update
        'update'
      when :destroy
        'delete'
      else
        nil
      end
    end
  end
end
