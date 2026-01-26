# frozen_string_literal: true

# API::V1::RolesController
#
# Manages roles and their permissions for companies using RBAC system.
# Supports CRUD operations, permission management, and system role cloning.

module Api
  module V1
    class RolesController < ApplicationController
      before_action :ensure_rbac_enabled, except: [:system_roles, :index]
      before_action :set_role, only: [:show, :update, :destroy, :clone, :permissions, :set_permissions]
      before_action :authorize_role_management, except: [:index, :show, :system_roles, :permissions, :toggle_visibility]
      
      # GET /api/v1/roles
      # FIX: Include permissions by default for proper matrix display
      def index
        if current_user.super_admin?
          @roles = Role.system_roles.active
        else
          @roles = Role.where(
            '(is_system_role = ? AND company_id IS NULL) OR company_id = ?',
            true,
            current_company_id
          ).active.order(:tier, :name)
        end
        
        # FIX: Include permissions in index to avoid N+1 queries in frontend
        render json: {
          roles: @roles.map { |role| serialize_role(role, include_permissions: true) }
        }
      end
      
      # GET /api/v1/roles/system
      def system_roles
        @roles = Role.system_roles.active.order(:tier, :name)
        
        render json: {
          roles: @roles.map { |role| serialize_role(role, include_permissions: true) }
        }
      end
      
      # GET /api/v1/roles/:id
      def show
        render json: {
          role: serialize_role(@role, include_permissions: true)
        }
      end
      
      # GET /api/v1/roles/:id/permissions
      # Returns role permissions in array format for frontend compatibility
      def permissions
        # Get all permissions for this role
        role_permissions = @role.role_permissions.granted.includes(:resource, :action, :scope)
        
        # Transform to frontend format
        permissions_data = role_permissions.map do |perm|
          {
            id: perm.id,
            resource_id: perm.resource_id,
            action_id: perm.action_id,
            scope_id: perm.scope_id,
            granted: perm.granted
          }
        end
        
        # Get all available metadata
        resources_data = Resource.active.order(:position, :name).map do |resource|
          {
            id: resource.id,
            key: resource.key,
            name: resource.name,
            display_name: resource.name,
            category: resource.category,
            description: resource.description,
            permission_ui_type: resource.permission_ui_type || 'standard_crud',
            permission_groups: resource.permission_groups || {}
          }
        end
        
        actions_data = Action.order(:key).map do |action|
          {
            id: action.id,
            key: action.key,
            name: action.name,
            display_name: action.name,
            description: action.description
          }
        end
        
        scopes_data = Scope.order(:key).map do |scope|
          {
            id: scope.id,
            key: scope.key,
            name: scope.name,
            display_name: scope.name,
            description: scope.description
          }
        end
        
        render json: {
          role: serialize_role(@role),
          permissions: permissions_data,
          resources: resources_data,
          actions: actions_data,
          scopes: scopes_data
        }
      end
      
      # PUT /api/v1/roles/:id/permissions
      # Set permissions for a role (replaces all existing permissions)
      def set_permissions
        Rails.logger.info "[RolesController] set_permissions called for role #{params[:id]}"
        Rails.logger.info "[RolesController] Received #{params[:permissions]&.length || 0} permissions"
        unless params[:permissions].is_a?(Array)
          render json: {
            error: 'Invalid permissions format - expected array'
          }, status: :unprocessable_entity
          return
        end
        
        ActiveRecord::Base.transaction do
          # Build a set of permission keys for the new permissions
          new_permission_keys = Set.new
          params[:permissions].each do |perm_data|
            key = "#{perm_data[:resource_id]}-#{perm_data[:action_id]}-#{perm_data[:scope_id]}"
            new_permission_keys.add(key)
          end
          
          # Delete permissions that are not in the new set
          @role.role_permissions.each do |existing_perm|
            key = "#{existing_perm.resource_id}-#{existing_perm.action_id}-#{existing_perm.scope_id}"
            unless new_permission_keys.include?(key)
              existing_perm.destroy
            end
          end
          
          # Create or update permissions
          params[:permissions].each do |perm_data|
            # Validate IDs exist
            unless Resource.exists?(perm_data[:resource_id])
              raise ActiveRecord::RecordInvalid.new("Resource with ID #{perm_data[:resource_id]} not found")
            end
            unless Action.exists?(perm_data[:action_id])
              raise ActiveRecord::RecordInvalid.new("Action with ID #{perm_data[:action_id]} not found")
            end
            unless Scope.exists?(perm_data[:scope_id])
              raise ActiveRecord::RecordInvalid.new("Scope with ID #{perm_data[:scope_id]} not found")
            end
            
            # Find or initialize the permission
            permission = @role.role_permissions.find_or_initialize_by(
              resource_id: perm_data[:resource_id],
              action_id: perm_data[:action_id],
              scope_id: perm_data[:scope_id]
            )
            
            # Update granted status
            permission.granted = perm_data[:granted] || true
            
            # Save if new or changed
            if permission.new_record? || permission.changed?
              permission.save!
            end
          end
        end
        
        # Clear any caches
        Rails.cache.clear
        
        # Return updated permissions
        permissions
      rescue ActiveRecord::RecordInvalid => e
        error_message = e.respond_to?(:record) ? e.record.errors.full_messages.join(', ') : e.message
        render json: {
          error: 'Failed to update permissions',
          errors: [error_message]
        }, status: :unprocessable_entity
      rescue StandardError => e
        Rails.logger.error "[RolesController] set_permissions error: #{e.message}"
        Rails.logger.error e.backtrace.join("\n")
        render json: {
          error: 'Failed to update permissions',
          errors: [e.message]
        }, status: :unprocessable_entity
      end
      
      # POST /api/v1/roles
      def create
        @role = Role.new(role_params)
        @role.company_id = current_company_id
        @role.is_system_role = false
        @role.active = true
        
        if @role.save
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
      def update
        if @role.system_role? && !current_user.super_admin?
          render json: {
            error: 'Only platform administrators can modify system roles'
          }, status: :forbidden
          return
        end
        
        if @role.update(role_params)
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
      def destroy
        if @role.system_role?
          render json: {
            error: 'Cannot delete system roles'
          }, status: :forbidden
          return
        end
        
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
      
      # POST /api/v1/roles/:id/toggle_visibility
      # Toggle whether a system role is hidden for the current company
      def toggle_visibility
        role = Role.find(params[:id])
        
        unless role.system_role?
          render json: {
            error: 'Can only toggle visibility for system roles'
          }, status: :unprocessable_entity
          return
        end
        
        if CompanyHiddenRole.role_hidden_for_company?(current_company_id, role.id)
          CompanyHiddenRole.show_role_for_company(current_company_id, role.id)
          message = "Role '#{role.name}' is now visible"
          is_hidden = false
        else
          CompanyHiddenRole.hide_role_for_company(current_company_id, role.id)
          message = "Role '#{role.name}' is now hidden"
          is_hidden = true
        end
        
        render json: {
          message: message,
          role: serialize_role(role),
          is_hidden: is_hidden
        }
      rescue ActiveRecord::RecordNotFound
        render json: { error: 'Role not found' }, status: :not_found
      end
      
      # POST /api/v1/roles/:id/clone
      def clone
        unless @role.system_role?
          render json: {
            error: 'Can only clone system roles'
          }, status: :unprocessable_entity
          return
        end
        
        new_role = @role.dup
        new_role.company_id = current_company_id
        new_role.is_system_role = false
        new_role.key = params[:name] || "#{@role.key}_#{SecureRandom.hex(4)}"
        new_role.name = params[:display_name] || "#{@role.name} (Custom)"
        new_role.description = params[:description] || @role.description
        new_role.tier = params[:tier] || 'company'
        
        if new_role.save
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
          :description,
          :color,
          :is_active,
          :active
        )
      end
      
      def serialize_role(role, include_permissions: false)
        data = {
          id: role.id,
          key: role.key,
          name: role.name,
          display_name: role.name,
          description: role.description,
          tier: role.tier,
          color: role.color,
          is_system: role.is_system_role,
          is_active: role.active,
          active: role.active,  # ✅ Add for frontend compatibility
          is_hidden_for_company: role.system_role? && current_company_id ? role.hidden_for_company?(current_company_id) : false,
          company_id: role.company_id,
          users_count: role.user_role_assignments.count,
          created_at: role.created_at,
          updated_at: role.updated_at
        }
        
        if include_permissions
          data[:permissions] = role.role_permissions.granted.includes(:resource, :action, :scope).map do |perm|
            {
              id: perm.id,
              resource_id: perm.resource_id,
              action_id: perm.action_id,
              scope_id: perm.scope_id,
              resource: perm.resource.key,
              resource_name: perm.resource.name,
              action: perm.action.key,
              action_name: perm.action.name,
              scope: perm.scope.key,
              scope_name: perm.scope.name,
              granted: perm.granted
            }
          end
        end
        
        data
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
