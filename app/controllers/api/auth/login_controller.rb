# frozen_string_literal: true

module Api
  module Auth
    class LoginController < ApplicationController
      skip_before_action :authenticate, only: [:create, :refresh]
      before_action :authenticate_user_from_token!, only: [:verify, :me]

      # POST /api/auth/login
      def create
        user = User.find_by(email: params[:email]&.downcase)

        if user&.authenticate(params[:password])
          if user.inactive? || user.suspended?
            render json: {
              success: false,
              message: 'Your account has been deactivated. Please contact support.'
            }, status: :forbidden
            return
          end

          # Check if user has MFA enabled
          if user.mfa_enabled?
            # Generate temporary token for MFA verification
            temp_token = JsonWebToken.generate_mfa_temp_token(user)
            
            render json: {
              success: true,
              mfa_required: true,
              temp_token: temp_token,
              message: 'Please enter your authentication code'
            }, status: :ok
            return
          end

          # No MFA - proceed with normal login flow
          # Generate tokens using JsonWebToken for consistency with ApplicationController
          tokens = JsonWebToken.generate_token_pair(user)
          
          user.update(last_sign_in_at: Time.current)
          
          # Track login activity
          LoginActivity.record_login(
            user_id: user.id,
            user_type: 'User',
            ip_address: request.remote_ip,
            user_agent: request.user_agent
          )

          set_refresh_token_cookie(tokens[:refresh_token])

          render json: {
            success: true,
            message: 'Login successful',
            token: tokens[:access_token],
            refreshToken: tokens[:refresh_token],
            user: build_user_response(user),
            requires_company_selection: requires_company_selection?(user),
            requires_location_selection: requires_location_selection?(user)
          }, status: :ok
        else
          render json: {
            success: false,
            message: 'Invalid email or password'
          }, status: :unauthorized
        end
      rescue StandardError => e
        Rails.logger.error("Login error: #{e.message}")
        Rails.logger.error(e.backtrace.first(10).join("\n"))
        render json: {
          success: false,
          message: 'An error occurred during login. Please try again.'
        }, status: :internal_server_error
      end

      # POST /api/auth/logout
      def destroy
        cookies.delete(:refresh_token, domain: :all, secure: Rails.env.production?)

        render json: {
          success: true,
          message: 'Logout successful'
        }, status: :ok
      rescue StandardError => e
        Rails.logger.error("Logout error: #{e.message}")
        render json: {
          success: false,
          message: 'An error occurred during logout'
        }, status: :internal_server_error
      end

      # POST /api/auth/refresh
      def refresh
        refresh_token = cookies[:refresh_token] || params[:refreshToken]

        if refresh_token.blank?
          render json: {
            success: false,
            message: 'Refresh token is required'
          }, status: :unauthorized
          return
        end

        begin
          # Use JsonWebToken for consistency
          decoded = JsonWebToken.decode(refresh_token)
          
          unless decoded && decoded[:type] == 'refresh'
            render json: {
              success: false,
              message: 'Invalid refresh token'
            }, status: :unauthorized
            return
          end

          user = User.find(decoded[:user_id])

          if user.inactive? || user.suspended?
            render json: {
              success: false,
              message: 'Account is not active'
            }, status: :forbidden
            return
          end

          # Generate new access token
          new_access_token = JsonWebToken.generate_access_token(user)

          render json: {
            success: true,
            token: new_access_token
          }, status: :ok
        rescue ActiveRecord::RecordNotFound
          render json: {
            success: false,
            message: 'User not found'
          }, status: :unauthorized
        end
      end

      # GET /api/auth/verify
      def verify
        render json: {
          success: true,
          valid: true,
          user: build_user_response(current_user)
        }, status: :ok
      end

      # GET /api/auth/me
      def me
        render json: {
          success: true,
          user: build_user_response(current_user)
        }, status: :ok
      end

      private

      attr_reader :current_user

      def authenticate_user_from_token!
        header = request.headers['Authorization']
        if header.blank?
          render json: {
            success: false,
            message: 'Authorization header is required'
          }, status: :unauthorized
          return
        end

        token = header.split(' ').last
        
        # Use JsonWebToken for consistency with ApplicationController
        decoded = JsonWebToken.decode(token)
        
        unless decoded
          render json: {
            success: false,
            message: 'Invalid or expired token'
          }, status: :unauthorized
          return
        end
        
        begin
          @current_user = User.find(decoded[:user_id])
        rescue ActiveRecord::RecordNotFound
          render json: {
            success: false,
            message: 'User not found'
          }, status: :unauthorized
        end
      end

      def set_refresh_token_cookie(token)
        cookies[:refresh_token] = {
          value: token,
          httponly: true,
          secure: Rails.env.production?,
          same_site: :strict,
          expires: 7.days.from_now
        }
      end

      def determine_user_type(user)
        return 'platform_admin' if user.platform_admin?
        return 'super_admin' if user.super_admin?
        return 'company_admin' if user.company_admin?  # Check RBAC-based company admin
        return 'admin' if user.admin?
        return 'client' if user.client?
        return 'staff' if user.staff?
        'staff'
      end

      # Build consistent user response with RBAC permissions
      def build_user_response(user)
        company = user.company
        
        # Get user's location assignments
        location_data = build_location_data(user, company)
        
        {
          id: user.id,
          email: user.email,
          firstName: user.first_name,
          lastName: user.last_name,
          user_type: determine_user_type(user),
          role: user.role,
          company_id: (user.platform_admin? || user.super_admin?) ? nil : user.company_id,
          companyName: company&.name,
          # RBAC information
          rbacEnabled: company&.use_rbac_system || false,
          permissions: build_permissions(user, company),
          roles: build_roles(user, company),
          # Custom field-level permissions
          custom_permissions: user.custom_permissions || [],
          # Location assignments for location-tier users
          user_tier: location_data[:user_tier],
          location_ids: location_data[:location_ids],
          location_role: location_data[:location_role],
          assigned_locations: location_data[:assigned_locations],
          # Company subscription and module access
          company: build_company_data(user, company)
        }
      end
      
      # Build location data for user response
      # Returns user_tier (company/location), location_ids, location_role, and detailed location info
      def build_location_data(user, company)
        # Platform/super admins and company-tier admins have company-level access
        return { user_tier: 'platform', location_ids: [], location_role: nil, assigned_locations: [] } if user.platform_admin? || user.super_admin?
        
        # Check if user has location-tier assignments
        user_locations = user.user_locations.active.includes(:location).where(company_id: company&.id)
        
        if user_locations.any?
          # User is location-tier - they have specific location assignments
          location_ids = user_locations.map(&:location_id)
          
          # Get the primary location role (use the highest-level role if multiple)
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
          # User is company-tier or has no location restrictions
          # Check RBAC roles to determine if they're company-tier
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

      # Build permissions array for frontend
      # Format: ["resource:action:scope", ...]
      # Platform/super admins get full access wildcard
      def build_permissions(user, company)
        # Platform admins and super admins have all permissions
        return ['*:*:*'] if user.platform_admin? || user.super_admin?
        
        # If RBAC is disabled, give all permissions
        return ['*:*:*'] unless company&.use_rbac_system
        
        # Get actual RBAC permissions
        user.permissions_for_company(company.id)
      end

      # Build roles array for frontend
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
      
      # Check if user needs to select a company (platform admins only)
      def requires_company_selection?(user)
        user.platform_admin? || user.super_admin?
      end
      
      # Check if user needs to select a location (multi-location users)
      def requires_location_selection?(user)
        return false if user.platform_admin? || user.super_admin?
        return false unless user.company.present?
        
        # Check accessible location count
        if user.uses_rbac? && !user.effective_admin?
          accessible_count = user.user_locations.active.where(company_id: user.company_id).count
          accessible_count > 1
        else
          # Company admins have access to all locations
          return false if user.admin?
          # Check total company locations
          user.company.locations.where(is_deleted: [false, nil], active: true).count > 1
        end
      end
      
      # Build company data including subscription and module access
      def build_company_data(user, company)
        return nil if user.platform_admin? || user.super_admin?
        return nil unless company.present?
        
        # Get module access service
        module_access = company.module_access
        subscription_status = module_access.subscription_status
        
        {
          id: company.id,
          name: company.name,
          # Module access
          enabled_modules: module_access.enabled_modules,
          module_configs: module_access.module_configs,
          # Subscription status
          subscription_status: subscription_status[:status],
          plan_name: subscription_status[:plan_name],
          plan_display_name: subscription_status[:plan_display_name],
          is_active: subscription_status[:is_active],
          is_trial: subscription_status[:is_trial],
          trial_days_remaining: subscription_status[:trial_days_remaining],
          in_grace_period: subscription_status[:in_grace_period],
          # Limits
          max_users: subscription_status.dig(:limits, :max_users),
          max_locations: subscription_status.dig(:limits, :max_locations),
          max_storage_gb: subscription_status.dig(:limits, :max_storage_gb)
        }
      end
    end
  end
end
