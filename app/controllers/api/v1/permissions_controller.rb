# frozen_string_literal: true

module Api
  module V1
    class PermissionsController < ApplicationController
      before_action :ensure_rbac_enabled
      
      # GET /api/v1/permissions/check
      # Check if current user has permission for a resource/action combination
      # Query params: resource (required), action_key (required), scope (optional, defaults to 'all')
      def check
        resource_key = params[:resource]
        action_key = params[:action_key]
        scope_key = params[:scope] || 'all'
        
        unless resource_key.present? && action_key.present?
          render json: {
            error: 'Missing required parameters: resource and action_key'
          }, status: :unprocessable_entity
          return
        end
        
        resource = Resource.find_by(key: resource_key)
        action = Action.find_by(key: action_key)
        scope = Scope.find_by(key: scope_key)
        
        unless resource && action && scope
          render json: {
            error: 'Invalid resource, action, or scope',
            allowed: false
          }, status: :not_found
          return
        end
        
        # Check if user has permission
        has_permission = check_user_permission(current_user, resource, action, scope)
        
        render json: {
          allowed: has_permission,
          resource: resource_key,
          action: action_key,
          scope: scope_key,
          user_id: current_user.id
        }
      end
      
      # POST /api/v1/permissions/bulk_check
      # Check multiple permissions at once
      # Body: { permissions: [{ resource: 'inventory', action: 'read', scope: 'all' }, ...] }
      def bulk_check
        permissions_to_check = params[:permissions] || []
        
        if permissions_to_check.empty?
          render json: {
            error: 'No permissions provided to check'
          }, status: :unprocessable_entity
          return
        end
        
        results = permissions_to_check.map do |perm|
          resource = Resource.find_by(key: perm[:resource])
          action = Action.find_by(key: perm[:action])
          scope = Scope.find_by(key: perm[:scope] || 'all')
          
          if resource && action && scope
            has_permission = check_user_permission(current_user, resource, action, scope)
            
            {
              resource: perm[:resource],
              action: perm[:action],
              scope: perm[:scope] || 'all',
              allowed: has_permission
            }
          else
            {
              resource: perm[:resource],
              action: perm[:action],
              scope: perm[:scope] || 'all',
              allowed: false,
              error: 'Invalid resource, action, or scope'
            }
          end
        end
        
        render json: {
          permissions: results,
          user_id: current_user.id
        }
      end
      
      # GET /api/v1/permissions/user/:user_id
      # Get all permissions for a specific user (admin only)
      def user_permissions
        unless current_user.admin? || current_user.company_admin?
          render json: {
            error: 'Forbidden - Only administrators can view user permissions'
          }, status: :forbidden
          return
        end
        
        user = User.find(params[:user_id])
        
        unless user.company_id == current_company_id
          render json: {
            error: 'User not found in your company'
          }, status: :not_found
          return
        end
        
        # Get all role assignments for the user
        role_assignments = user.user_role_assignments.includes(role: [:role_permissions])
        
        # Build permissions map
        permissions_map = {}
        
        role_assignments.each do |assignment|
          assignment.role.role_permissions.granted.includes(:resource, :action, :scope).each do |perm|
            key = "#{perm.resource.key}:#{perm.action.key}:#{perm.scope.key}"
            permissions_map[key] = {
              resource: perm.resource.key,
              resource_name: perm.resource.name,
              action: perm.action.key,
              action_name: perm.action.name,
              scope: perm.scope.key,
              scope_name: perm.scope.name,
              granted_by_role: assignment.role.name
            }
          end
        end
        
        render json: {
          user_id: user.id,
          user_email: user.email,
          permissions: permissions_map.values,
          roles: role_assignments.map { |ra| { id: ra.role.id, name: ra.role.name } }
        }
      end
      
      private
      
      def ensure_rbac_enabled
        unless current_company.use_rbac_system
          render json: {
            error: 'RBAC system is not enabled for this company',
            message: 'Please contact your administrator to enable role-based access control'
          }, status: :forbidden
        end
      end
      
      def check_user_permission(user, resource, action, scope)
        # Platform admins have all permissions
        return true if user.super_admin?
        
        # Check if user has any role with this permission
        user.user_role_assignments.includes(role: [:role_permissions]).any? do |assignment|
          assignment.role.role_permissions.exists?(
            resource: resource,
            action: action,
            scope: scope,
            granted: true
          )
        end
      end
    end
  end
end
