# frozen_string_literal: true

module Api
  module V1
    class UsersController < ApplicationController
      before_action :set_user, only: [:show, :update, :destroy]
      before_action :authorize_company_access!
      before_action :authorize_user_management!, only: [:create, :update, :destroy]

      # GET /api/v1/users
      def index
        # RBAC: Check if user can read users
        return unless authorize_action!('users', 'read')
        
        @users = current_company.users.where(deleted_at: nil)

        # Filter by status if provided
        if params[:status].present?
          @users = @users.where(status: params[:status])
        end

        # Filter by role if provided
        if params[:role].present?
          @users = @users.where(role: params[:role])
        end

        # Filter by location if provided
        if params[:location_id].present?
          location = current_company.locations.find(params[:location_id])
          @users = @users.joins(:user_locations)
                        .where(user_locations: { location_id: location.id, active: true })
                        .distinct
        end

        # Include deleted users if requested (requires delete permission)
        if params[:include_deleted] == 'true' && can?('users', 'delete')
          @users = current_company.users
        end

        @users = @users.order(created_at: :desc)

        render json: {
          users: @users.map { |user| user_json(user) },
          meta: {
            total: @users.count,
            company_id: current_company.id
          }
        }
      end

      # GET /api/v1/users/:id
      def show
        # RBAC: Check if user can read users
        return unless authorize_action!('users', 'read')
        
        render json: {
          user: user_json(@user, include_locations: true)
        }
      end

      # POST /api/v1/users
      def create
        # RBAC: Check if user can create users
        return unless authorize_action!('users', 'create')
        
        @user = current_company.users.build(user_params)
        @user.status ||= 'active'

        # Generate temporary password if not provided
        unless params[:user][:password].present?
          @user.password = SecureRandom.hex(16)
          @user.password_confirmation = @user.password
        end

        if @user.save
          # Assign RBAC role if company uses RBAC system
          if current_company&.use_rbac_system && @user.role.present?
            @user.assign_rbac_role(
              @user.role,
              company_id: current_company.id,
              assigned_by: current_user
            )
            Rails.logger.info "✅ [V1::UsersController] Assigned RBAC role '#{@user.role}' to new user #{@user.id}"
          end
          
          # Handle location assignments if provided
          if params[:location_ids].present?
            assign_locations_to_user(@user, params[:location_ids], params[:location_role])
          end

          render json: {
            user: user_json(@user, include_locations: true),
            message: 'User created successfully'
          }, status: :created
        else
          render json: {
            errors: @user.errors.full_messages
          }, status: :unprocessable_entity
        end
      end

      # PATCH/PUT /api/v1/users/:id
      def update
        # RBAC: Check if user can update users (or updating own profile)
        unless @user.id == current_user.id || can?('users', 'update')
          render json: { error: 'Forbidden - Insufficient permissions' }, status: :forbidden
          return
        end
        
        # Track reason for audit
        reason = params[:reason] || 'Updated via API'
        
        # Check if role is being changed
        new_role = params[:user][:role] if params[:user].present?
        role_changed = new_role.present? && new_role != @user.role

        if @user.update(user_params)
          # Handle RBAC role change if company uses RBAC system
          if role_changed && current_company&.use_rbac_system
            @user.replace_rbac_role(
              new_role,
              company_id: current_company.id,
              assigned_by: current_user
            )
            Rails.logger.info "✅ [V1::UsersController] Updated RBAC role to '#{new_role}' for user #{@user.id}"
          end
          
          # Handle location assignments if provided (only if user has manage permission)
          if params[:location_ids].present? && can?('users', 'manage')
            sync_user_locations(@user, params[:location_ids], params[:location_role])
          end

          # Log the update
          Rails.logger.info("[UsersController] User #{@user.id} updated by #{current_user.id}: #{reason}")

          render json: {
            user: user_json(@user, include_locations: true),
            message: 'User updated successfully'
          }
        else
          render json: {
            errors: @user.errors.full_messages
          }, status: :unprocessable_entity
        end
      end

      # DELETE /api/v1/users/:id
      def destroy
        # RBAC: Check if user can delete users
        return unless authorize_action!('users', 'delete')
        
        # Soft delete
        if @user.update(deleted_at: Time.current, status: 'inactive')
          # Deactivate all location assignments
          @user.user_locations.update_all(active: false)

          render json: {
            message: 'User deleted successfully'
          }
        else
          render json: {
            errors: ['Failed to delete user']
          }, status: :unprocessable_entity
        end
      end

      # GET /api/v1/users/assignable
      # Returns users filtered by assignment context (service, sales, finance, etc.)
      def assignable
        return unless authorize_action!('users', 'read')
        
        context = params[:context] || 'general'
        
        # Base query: all active users in company
        users = current_company.users.where(deleted_at: nil, status: 'active')
        
        # Apply RBAC location filtering for non-admins
        if current_user.uses_rbac? && !current_user.effective_admin?
          location_ids = permission_service.accessible_location_ids
          if location_ids.any?
            users = users.joins(:user_locations)
                        .where(user_locations: { location_id: location_ids, active: true })
                        .distinct
          end
        end
        
        # Smart filtering based on company setting
        if current_company.filter_assignments_by_role?
          users = filter_by_context(users, context)
        end
        
        # Order by name
        users = users.order(:first_name, :last_name)
        
        render json: {
          users: users.map { |u| assignable_user_json(u) }
        }
      end

      # GET /api/v1/users/:id/locations
      def user_locations
        @user = current_company.users.find(params[:id])
        
        # RBAC: Check if user can read users or accessing own profile
        unless @user.id == current_user.id || can?('users', 'read')
          render json: { error: 'Forbidden - Insufficient permissions' }, status: :forbidden
          return
        end

        @locations = @user.locations.where(is_deleted: false)
                         .includes(:user_locations)

        render json: {
          locations: @locations.map do |location|
            ul = @user.user_locations.find_by(location_id: location.id)
            {
              id: location.id,
              name: location.name,
              code: location.code,
              city: location.city,
              state: location.state,
              location_role: ul&.location_role,
              active: ul&.active,
              assigned_at: ul&.created_at
            }
          end
        }
      end

      # POST /api/v1/users/:id/assign_location
      def assign_location
        @user = current_company.users.find(params[:id])
        
        # RBAC: Check if user can manage users (assign permissions)
        return unless authorize_action!('users', 'assign')

        location = current_company.locations.find(params[:location_id])
        location_role = params[:location_role] || 'location_staff'

        ul = location.assign_user(@user, role: location_role, assigned_by: current_user.id.to_s)

        render json: {
          user_location: {
            user_id: ul.user_id,
            location_id: ul.location_id,
            location_role: ul.location_role,
            active: ul.active
          },
          message: 'User assigned to location successfully'
        }
      rescue ActiveRecord::RecordInvalid => e
        render json: {
          errors: [e.message]
        }, status: :unprocessable_entity
      end

      # DELETE /api/v1/users/:id/remove_location/:location_id
      def remove_location
        @user = current_company.users.find(params[:id])
        
        # RBAC: Check if user can manage users (assign permissions)
        return unless authorize_action!('users', 'assign')

        location = current_company.locations.find(params[:location_id])
        location.remove_user(@user)

        render json: {
          message: 'User removed from location successfully'
        }
      end

      # POST /api/v1/users/bulk_activate
      def bulk_activate
        # RBAC: Check if user can manage users
        return unless authorize_action!('users', 'manage')

        user_ids = params[:user_ids] || []
        users = current_company.users.where(id: user_ids)

        updated_count = 0
        users.each do |user|
          if user.update(status: 'active')
            updated_count += 1
          end
        end

        render json: {
          message: "#{updated_count} user(s) activated successfully",
          updated_count: updated_count
        }
      end

      # POST /api/v1/users/bulk_deactivate
      def bulk_deactivate
        # RBAC: Check if user can manage users
        return unless authorize_action!('users', 'manage')

        user_ids = params[:user_ids] || []
        users = current_company.users.where(id: user_ids)

        updated_count = 0
        users.each do |user|
          if user.update(status: 'inactive')
            updated_count += 1
          end
        end

        render json: {
          message: "#{updated_count} user(s) deactivated successfully",
          updated_count: updated_count
        }
      end

      # GET /api/v1/users/available_roles
      # Returns all roles (system + custom) that the current user can assign
      def available_roles
        # RBAC: Check if user can read users (needed to assign roles)
        return unless authorize_action!('users', 'read')
        
        # Get all active roles for this company
        roles = current_company.roles.where(active: true)
        
        # Format roles for frontend
        formatted_roles = roles.map do |role|
          {
            id: role.id,
            key: role.key,
            name: role.name,
            display_name: role.name,
            description: role.description,
            is_system: role.is_system,
            active: role.active,
            tier: role.tier
          }
        end
        
        render json: {
          roles: formatted_roles
        }
      end

      private

      def set_user
        @user = current_company.users.find(params[:id])
      rescue ActiveRecord::RecordNotFound
        render json: { error: 'User not found' }, status: :not_found
      end

      def user_params
        params.require(:user).permit(
          :email,
          :first_name,
          :last_name,
          :display_name,
          :mobile,
          :role,
          :status,
          :password,
          :password_confirmation
        )
      end

      def user_json(user, include_locations: false)
        json = {
          id: user.id,
          email: user.email,
          first_name: user.first_name,
          last_name: user.last_name,
          display_name: user.name,
          mobile: user.try(:mobile),
          role: user.role,
          status: user.status,
          company_id: user.company_id,
          created_at: user.created_at,
          updated_at: user.updated_at,
          deleted_at: user.deleted_at
        }

        if include_locations
          json[:locations] = user.user_locations.includes(:location)
                                .where(active: true)
                                .map do |ul|
            {
              id: ul.location_id,
              name: ul.location.name,
              location_role: ul.location_role,
              assigned_at: ul.created_at
            }
          end
        end

        json
      end

      def current_company
        @current_company ||= ::Company.find_by(id: current_company_id)
      end

      def authorize_company_access!
        unless current_company.present?
          render json: { error: 'No company associated with user' }, status: :forbidden
        end
      end

      def authorize_user_management!
        # RBAC-aware authorization for user management
        # Check if user can perform the specific action on users resource
        action = case action_name
                when 'create' then 'create'
                when 'update' then 'update'
                when 'destroy' then 'delete'
                else 'manage'
                end
        
        unless can?('users', action)
          render json: { 
            error: 'Forbidden - Insufficient permissions',
            required_permission: "users:#{action}"
          }, status: :forbidden
        end
      end

      def authorize_user_access!(user)
        # Company admins or users with read permission can access all users
        return if can?('users', 'read')

        # Users can access their own profile
        return if current_user.id == user.id

        # Otherwise, deny access
        render json: { error: 'Access denied' }, status: :forbidden
      end

      def assign_locations_to_user(user, location_ids, location_role = 'location_staff')
        location_ids = [location_ids] unless location_ids.is_a?(Array)
        
        location_ids.each do |location_id|
          location = current_company.locations.find_by(id: location_id)
          next unless location

          UserLocation.find_or_create_by!(
            user_id: user.id,
            location_id: location.id,
            company_id: current_company.id
          ) do |ul|
            ul.location_role = location_role || 'location_staff'
            ul.active = true
            ul.assigned_by = current_user.id.to_s
          end
        end
      end

      def sync_user_locations(user, location_ids, location_role = 'location_staff')
        location_ids = [location_ids] unless location_ids.is_a?(Array)
        
        # Deactivate locations not in the new list
        user.user_locations.where.not(location_id: location_ids).update_all(active: false)

        # Add or reactivate locations in the new list
        location_ids.each do |location_id|
          location = current_company.locations.find_by(id: location_id)
          next unless location

          ul = UserLocation.find_or_initialize_by(
            user_id: user.id,
            location_id: location.id,
            company_id: current_company.id
          )

          ul.location_role = location_role || ul.location_role || 'location_staff'
          ul.active = true
          ul.assigned_by = current_user.id.to_s if ul.new_record?
          ul.save!
        end
      end
      
      # Filter users by assignment context using RBAC permissions or role departments
      def filter_by_context(users, context)
        case context
        when 'service'
          filter_users_by_department(users, 'service', ['service'])
        when 'sales'
          filter_users_by_department(users, 'sales', ['sales', 'quotes', 'deals'])
        when 'finance'
          filter_users_by_department(users, 'finance', ['payments', 'invoices'])
        when 'crm'
          filter_users_by_department(users, 'crm', ['crm', 'contacts', 'leads'])
        when 'inventory'
          filter_users_by_department(users, 'operations', ['inventory', 'operations', 'vehicles'])
        else
          users # Return all users for 'general' context
        end
      end
      
      # Helper to filter users by department or RBAC permissions
      def filter_users_by_department(users, department, resource_keys)
        if current_company.use_rbac_system
          # RBAC: Find users with permissions for these resources
          user_ids = UserRoleAssignment
            .joins(role: :role_permissions)
            .joins('INNER JOIN resources ON resources.id = role_permissions.resource_id')
            .where(user_role_assignments: { company_id: current_company.id })
            .where(resources: { key: resource_keys })
            .where(role_permissions: { granted: true })
            .distinct
            .pluck(:user_id)
          
          # Also include users with roles that have matching department
          dept_user_ids = UserRoleAssignment
            .joins(:role)
            .where(user_role_assignments: { company_id: current_company.id })
            .where(roles: { department: department })
            .distinct
            .pluck(:user_id)
          
          combined_ids = (user_ids + dept_user_ids).uniq
          combined_ids.any? ? users.where(id: combined_ids) : users.none
        else
          # Legacy: No RBAC, return all users (small company use case)
          users
        end
      end
      
      # JSON serialization for assignable users
      def assignable_user_json(user)
        # Get role display name
        role_display = if current_company.use_rbac_system && user.user_role_assignments.any?
          primary_assignment = user.user_role_assignments
            .where(company_id: current_company.id)
            .joins(:role)
            .order('roles.tier DESC, roles.created_at ASC')
            .first
          primary_assignment&.role&.name || user.role&.titleize || 'User'
        else
          user.role&.titleize || 'User'
        end
        
        {
          id: user.id,
          firstName: user.first_name,
          lastName: user.last_name,
          fullName: user.name,
          email: user.email,
          role: user.role,
          displayRole: role_display,
          avatarUrl: user.try(:avatar_url),
          locations: user.user_locations.includes(:location).where(active: true).map do |ul|
            {
              id: ul.location_id,
              name: ul.location.name
            }
          end
        }
      end
    end
  end
end
