# frozen_string_literal: true

module Api
  module Auth
    class ImpersonationController < ApplicationController
      # Must be platform admin to impersonate
      before_action :require_platform_admin!
      
      # POST /api/auth/impersonate
      # Impersonate a user - returns their full context like login does
      def create
        target_user_id = params[:user_id]
        company_id = params[:company_id]
        
        unless target_user_id.present?
          return render json: {
            success: false,
            error: 'User ID is required'
          }, status: :bad_request
        end
        
        # Find target user
        target_user = User.find_by(id: target_user_id)
        
        unless target_user
          return render json: {
            success: false,
            error: 'User not found'
          }, status: :not_found
        end
        
        # Verify company_id matches if provided
        if company_id.present? && target_user.company_id.to_s != company_id.to_s
          return render json: {
            success: false,
            error: 'User does not belong to specified company'
          }, status: :bad_request
        end
        
        # Check if target user is active
        if target_user.inactive? || target_user.suspended?
          return render json: {
            success: false,
            error: 'Cannot impersonate inactive or suspended user'
          }, status: :forbidden
        end
        
        # Log impersonation start
        Rails.logger.info "🎭 [IMPERSONATION] Platform admin #{current_user.email} (ID: #{current_user.id}) is impersonating #{target_user.email} (ID: #{target_user.id})"
        
        # Track login activity
        LoginActivity.record_login(
          user_id: target_user.id,
          user_type: 'User',
          ip_address: request.remote_ip,
          user_agent: request.user_agent
        )
        
        # Return full user context (same as login response)
        render json: {
          success: true,
          impersonation: true,
          original_user: {
            id: current_user.id,
            email: current_user.email,
            name: current_user.name
          },
          user: build_user_response(target_user)
        }, status: :ok
      rescue StandardError => e
        Rails.logger.error("Impersonation error: #{e.message}")
        Rails.logger.error(e.backtrace.first(10).join("\n"))
        render json: {
          success: false,
          error: 'Failed to start impersonation'
        }, status: :internal_server_error
      end
      
      # POST /api/auth/stop_impersonation
      # Stop impersonating and return to original admin context
      def destroy
        # Log impersonation end
        Rails.logger.info "🎭 [IMPERSONATION] Platform admin #{current_user.email} (ID: #{current_user.id}) stopped impersonation"
        
        # Return original platform admin context
        render json: {
          success: true,
          message: 'Impersonation stopped',
          user: build_user_response(current_user)
        }, status: :ok
      rescue StandardError => e
        Rails.logger.error("Stop impersonation error: #{e.message}")
        render json: {
          success: false,
          error: 'Failed to stop impersonation'
        }, status: :internal_server_error
      end
      
      private
      
      def require_platform_admin!
        unless current_user.platform_admin? || current_user.super_admin?
          render json: {
            success: false,
            error: 'Only platform administrators can impersonate users'
          }, status: :forbidden
        end
      end
      
      # Build consistent user response with RBAC permissions and subscription data
      def build_user_response(user)
        company = user.company
        location_data = build_location_data(user, company)
        
        {
          id: user.id,
          email: user.email,
          firstName: user.first_name,
          lastName: user.last_name,
          name: user.name,
          user_type: determine_user_type(user),
          role: user.role,
          company_id: (user.platform_admin? || user.super_admin?) ? nil : user.company_id,
          companyName: company&.name,
          rbac_enabled: company&.use_rbac_system || false,
          permissions: build_permissions(user, company),
          roles: build_roles(user, company),
          user_tier: location_data[:user_tier],
          location_ids: location_data[:location_ids],
          location_role: location_data[:location_role],
          assigned_locations: location_data[:assigned_locations],
          company: build_company_data(user, company)
        }
      end
      
      def determine_user_type(user)
        return 'platform_admin' if user.platform_admin?
        return 'super_admin' if user.super_admin?
        return 'company_admin' if user.company_admin?
        return 'admin' if user.admin?
        return 'client' if user.client?
        return 'staff' if user.staff?
        'staff'
      end
      
      def build_permissions(user, company)
        return ['*:*:*'] if user.platform_admin? || user.super_admin?
        return ['*:*:*'] unless company&.use_rbac_system
        user.permissions_for_company(company.id)
      end
      
      def build_roles(user, company)
        return [{ key: 'platform_admin', name: 'Platform Admin', tier: 'platform' }] if user.platform_admin?
        return [{ key: 'super_admin', name: 'Super Admin', tier: 'platform' }] if user.super_admin?
        return [] unless company&.use_rbac_system
        
        user.roles_for_company(company.id).map do |role|
          {
            key: role.key,
            name: role.name,
            tier: role.tier,
            color: role.color
          }
        end
      end
      
      def build_location_data(user, company)
        return { user_tier: 'platform', location_ids: [], location_role: nil, assigned_locations: [] } if user.platform_admin? || user.super_admin?
        
        user_locations = user.user_locations.active.includes(:location).where(company_id: company&.id)
        
        if user_locations.any?
          location_ids = user_locations.map(&:location_id)
          role_priority = { 'location_admin' => 3, 'location_manager' => 2, 'location_staff' => 1 }
          primary_assignment = user_locations.max_by { |ul| role_priority[ul.location_role] || 0 }
          
          assigned_locations = user_locations.map do |ul|
            {
              id: ul.location_id,
              name: ul.location&.name,
              code: ul.location&.code,
              role: ul.location_role
            }
          end
          
          {
            user_tier: 'location',
            location_ids: location_ids,
            location_role: primary_assignment&.location_role,
            assigned_locations: assigned_locations
          }
        else
          is_company_tier = user.company_admin? || 
                            user.roles_for_company(company&.id).any? { |r| r.tier == 'company' }
          
          {
            user_tier: is_company_tier ? 'company' : 'location',
            location_ids: [],
            location_role: nil,
            assigned_locations: []
          }
        end
      end
      
      def build_company_data(user, company)
        return nil if user.platform_admin? || user.super_admin?
        return nil unless company.present?
        
        module_access = company.module_access
        subscription_status = module_access.subscription_status
        
        {
          id: company.id,
          name: company.name,
          enabled_modules: module_access.enabled_modules,
          subscription_status: subscription_status[:status],
          plan_name: subscription_status[:plan_name],
          plan_display_name: subscription_status[:plan_display_name],
          is_active: subscription_status[:is_active],
          is_trial: subscription_status[:is_trial],
          trial_days_remaining: subscription_status[:trial_days_remaining],
          in_grace_period: subscription_status[:in_grace_period],
          max_users: subscription_status.dig(:limits, :max_users),
          max_locations: subscription_status.dig(:limits, :max_locations),
          max_storage_gb: subscription_status.dig(:limits, :max_storage_gb)
        }
      end
    end
  end
end
