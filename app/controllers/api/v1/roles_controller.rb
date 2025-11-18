# frozen_string_literal: true

# API::V1::RolesController
#
# Manages roles and their permissions for companies using RBAC system.
# Supports CRUD operations, permission management, and system role cloning.
#
# Authorization:
# - Company admins can manage company-level roles
# - Platform admins can manage system roles
#
# Routes:
#   GET    /api/v1/roles           - List all roles
#   GET    /api/v1/roles/:id       - Show role details
#   POST   /api/v1/roles           - Create new role
#   PATCH  /api/v1/roles/:id       - Update role
#   DELETE /api/v1/roles/:id       - Delete role
#   POST   /api/v1/roles/:id/clone - Clone system role to company
#   GET    /api/v1/roles/system    - List system default roles
#   GET    /api/v1/roles/:id/permissions - Get role permissions matrix

module Api
  module V1
    class RolesController < ApplicationController
      before_action :ensure_rbac_enabled, except: [:system_roles]
      before_action :set_role, only: [:show, :update, :destroy, :clone, :permissions]
      before_action :authorize_role_management, except: [:index, :show, :system_roles, :permissions]
      
      # GET /api/v1/roles
      # List all roles accessible to current user
      def index
        if current_user.super_admin?
          # Platform admins see all system roles
          @roles = Role.system_roles.active
        else
          # Company users see system roles + their company's custom roles
          @roles = Role.where(
            '(is_system_role = ? AND company_id IS NULL) OR company_id = ?',
            true,
            current_company_id
          ).active.order(:tier, :name)
        end
        
        render json: {
          roles: @roles.map { |role| serialize_role(role) }
        }
      end
      
      # GET /api/v1/roles/system
      # List system default roles (available to all companies)
      def system_roles
        @roles = Role.system_roles.active.order(:tier, :name)
        
        render json: {
          roles: @roles.map { |role| serialize_role(role, include_permissions: true) }
        }
      end
      
      # GET /api/v1/roles/:id
      # Show role details
      def show
        render json: {
          role: serialize_role(@role, include_permissions: true)
        }
      end
      
      # GET /api/v1/roles/:id/permissions
      # Get role permissions matrix
      def permissions
        permissions_matrix = build_permissions_matrix(@role)
        
        render json: {
          role: serialize_role(@role),
          permissions: permissions_matrix
        }
      end
      
      # POST /api/v1/roles
      # Create new company-specific role
      def create
        @role = Role.new(role_params)
        @role.company_id = current_company_id
        @role.is_system_role = false
        @role.active = true
        
        if @role.save
          # Apply permissions if provided
          if params[:permissions].present?
            apply_permissions(@role, params[:permissions])
          end
          
          render json: {
            role: serialize_role(@role, include_permissions: true),
            message: 'Role created successfully'
          }, status: :created
        else
          render json: {
            error: 'Failed to create role',
            errors: @role.errors.full_messages
          }, status: :unprocessable_entity
        end
      end
      
      # PATCH /api/v1/roles/:id
      # Update role details and permissions
      def update
        if @role.system_role?
          render json: {
            error: 'Cannot modify system roles'
          }, status: :forbidden
          return
        end
        
        if @role.update(role_params)
          # Update permissions if provided
          if params[:permissions].present?
            apply_permissions(@role, params[:permissions])
          end
          
          render json: {
            role: serialize_role(@role, include_permissions: true),
            message: 'Role updated successfully'
          }
        else
          render json: {
            error: 'Failed to update role',
            errors: @role.errors.full_messages
          }, status: :unprocessable_entity
        end
      end
      
      # DELETE /api/v1/roles/:id
      # Delete custom role (system roles cannot be deleted)
      def destroy
        if @role.system_role?
          render json: {
            error: 'Cannot delete system roles'
          }, status: :forbidden
          return
        end
        
        # Check if role is in use
        if @role.user_role_assignments.exists?
          render json: {
            error: 'Cannot delete role that is assigned to users',
            users_count: @role.user_role_assignments.count
          }, status: :unprocessable_entity
          return
        end
        
        @role.destroy
        
        render json: {
          message: 'Role deleted successfully'
        }
      end
      
      # POST /api/v1/roles/:id/clone
      # Clone system role to company (create customizable copy)
      def clone
        unless @role.system_role?
          render json: {
            error: 'Can only clone system roles'
          }, status: :unprocessable_entity
          return
        end
        
        # Create company-specific copy
        new_role = @role.dup
        new_role.company_id = current_company_id
        new_role.is_system_role = false
        new_role.key = "#{@role.key}_custom_#{Time.now.to_i}"
        new_role.name = params[:name] || "#{@role.name} (Custom)"
        new_role.description = params[:description] || @role.description
        
        if new_role.save
          # Copy all permissions
          @role.role_permissions.each do |permission|
            RolePermission.create!(
              role: new_role,
              resource_id: permission.resource_id,
              action_id: permission.action_id,
              scope_id: permission.scope_id,
              granted: permission.granted
            )
          end
          
          render json: {
            role: serialize_role(new_role, include_permissions: true),
            message: 'Role cloned successfully'
          }, status: :created
        else
          render json: {
            error: 'Failed to clone role',
            errors: new_role.errors.full_messages
          }, status: :unprocessable_entity
        end
      end
      
      private
      
      def set_role
        @role = if current_user.super_admin?
          Role.find(params[:id])
        else
          Role.where(
            '(is_system_role = ? AND company_id IS NULL) OR company_id = ?',
            true,
            current_company_id
          ).find(params[:id])
        end
      rescue ActiveRecord::RecordNotFound
        render json: { error: 'Role not found' }, status: :not_found
      end
      
      def ensure_rbac_enabled
        unless current_company.use_rbac_system
          render json: {
            error: 'RBAC system is not enabled for this company',
            message: 'Please contact your administrator to enable role-based access control'
          }, status: :forbidden
        end
      end
      
      def authorize_role_management
        unless current_user.admin? || current_user.company_admin?
          render json: {
            error: 'Forbidden - Only administrators can manage roles'
          }, status: :forbidden
        end
      end
      
      def role_params
        params.require(:role).permit(
          :tier,
          :key,
          :name,
          :description
        )
      end
      
      def serialize_role(role, include_permissions: false)
        data = {
          id: role.id,
          key: role.key,
          name: role.name,
          description: role.description,
          tier: role.tier,
          is_system_role: role.is_system_role,
          active: role.active,
          users_count: role.user_role_assignments.count,
          created_at: role.created_at,
          updated_at: role.updated_at
        }
        
        if include_permissions
          data[:permissions] = role.role_permissions.granted.includes(:resource, :action, :scope).map do |perm|
            {
              resource: perm.resource.key,
              resource_name: perm.resource.name,
              action: perm.action.key,
              action_name: perm.action.name,
              scope: perm.scope.key,
              scope_name: perm.scope.name
            }
          end
        end
        
        data
      end
      
      def build_permissions_matrix(role)
        resources = Resource.active.order(:category, :name)
        actions = Action.order(:key)
        scopes = Scope.order(:key)
        
        matrix = {}
        
        resources.each do |resource|
          matrix[resource.key] = {
            name: resource.name,
            category: resource.category,
            actions: {}
          }
          
          actions.each do |action|
            matrix[resource.key][:actions][action.key] = {
              name: action.name,
              scopes: {}
            }
            
            scopes.each do |scope|
              permission = role.role_permissions.find_by(
                resource_id: resource.id,
                action_id: action.id,
                scope_id: scope.id
              )
              
              matrix[resource.key][:actions][action.key][:scopes][scope.key] = {
                name: scope.name,
                granted: permission&.granted || false,
                permission_id: permission&.id
              }
            end
          end
        end
        
        matrix
      end
      
      def apply_permissions(role, permissions_data)
        return unless permissions_data.is_a?(Array)
        
        permissions_data.each do |perm_data|
          resource = Resource.find_by(key: perm_data[:resource])
          action = Action.find_by(key: perm_data[:action])
          scope = Scope.find_by(key: perm_data[:scope] || 'all')
          
          next unless resource && action && scope
          
          role_permission = role.role_permissions.find_or_initialize_by(
            resource: resource,
            action: action,
            scope: scope
          )
          
          role_permission.granted = perm_data[:granted]
          role_permission.save!
        end
      end
    end
  end
end
