# frozen_string_literal: true

module Api
  module Auth
    class MfaController < ApplicationController
      skip_before_action :authenticate, only: [:request_code, :verify_code]

      # POST /api/auth/mfa/request_code
      # Request a new MFA code during login
      def request_code
        email = params[:email]
        user_type = params[:user_type] || 'user'
        # Don't use params[:delivery_method] - read from user's saved preference instead

        # Validate parameters
        if email.blank?
          render json: {
            success: false,
            error: 'Email is required'
          }, status: :bad_request
          return
        end

        # Find user by email
        if user_type == 'portal'
          user = BuyerPortalAccess.find_by(email: email.downcase)
          actual_user_type = 'BuyerPortalAccess'
        else
          user = User.find_by(email: email.downcase)
          actual_user_type = 'User'
        end
        
        unless user
          render json: {
            success: false,
            error: 'User not found'
          }, status: :not_found
          return
        end
        
        # Use user's saved MFA method preference, but allow override for fallback
        # This lets frontend request alternate method if primary delivery fails
        requested_method = params[:delivery_method]
        delivery_method = if requested_method.present? && %w[email sms].include?(requested_method)
          requested_method
        else
          user.mfa_method || 'email'
        end

        # Request MFA code
        service = MfaService.new(
          ip_address: request.remote_ip,
          user_agent: request.user_agent
        )

        result = service.request_code(
          user: user,
          user_type: actual_user_type,
          delivery_method: delivery_method
        )

        render json: result, status: :ok
      rescue MfaService::RateLimitError => e
        render json: {
          success: false,
          error: e.message
        }, status: :too_many_requests
      rescue MfaService::DeliveryDisabledError => e
        render json: {
          success: false,
          error: e.message
        }, status: :unprocessable_entity
      rescue MfaService::DeliveryFailedError => e
        render json: {
          success: false,
          error: 'Failed to send verification code. Please try again.'
        }, status: :internal_server_error
      rescue StandardError => e
        Rails.logger.error("MFA request error: #{e.message}")
        Rails.logger.error(e.backtrace.join("\n"))
        render json: {
          success: false,
          error: 'An error occurred. Please try again later.'
        }, status: :internal_server_error
      end

      # POST /api/auth/mfa/verify_code
      # Verify MFA code and complete login
      def verify_code
        temp_token = params[:temp_token]
        code = params[:code]
        user_type = params[:user_type] || 'user'

        # Validate parameters
        if temp_token.blank? || code.blank?
          render json: {
            success: false,
            error: 'Temporary token and code are required'
          }, status: :bad_request
          return
        end

        # Decode temp token to get user info
        decoded = JsonWebToken.decode(temp_token)
        
        unless decoded && (decoded[:type] == 'mfa_temp' || decoded[:type] == 'mfa_temp_portal')
          render json: {
            success: false,
            error: 'Invalid or expired temporary token'
          }, status: :unauthorized
          return
        end

        # Find user based on token type
        if decoded[:type] == 'mfa_temp_portal'
          user = BuyerPortalAccess.find_by(id: decoded[:buyer_portal_access_id])
          actual_user_type = 'BuyerPortalAccess' # ⭐ FIX: Use class name for polymorphic association
        else
          user = User.find_by(id: decoded[:user_id])
          actual_user_type = 'User' # ⭐ FIX: Use class name for polymorphic association
        end
        
        unless user
          render json: {
            success: false,
            error: 'User not found'
          }, status: :not_found
          return
        end

        # Verify code
        service = MfaService.new(
          ip_address: request.remote_ip,
          user_agent: request.user_agent
        )

        service.verify_code(
          user: user,
          user_type: actual_user_type,
          code: code
        )

        # Record login
        if user.respond_to?(:record_login!)
          user.record_login!(request.remote_ip)
        else
          user.update(last_sign_in_at: Time.current) if user.respond_to?(:last_sign_in_at=)
        end
        
        # Track login activity
        LoginActivity.record_login(
          user_id: user.id,
          user_type: actual_user_type,
          ip_address: request.remote_ip,
          user_agent: request.user_agent
        )

        # Generate JWT token for login
        jwt_token = generate_auth_token(user)
        user_data = serialize_user(user, actual_user_type)

        render json: {
          success: true,
          message: 'Verification successful',
          token: jwt_token,
          user: user_data,
          requires_company_selection: requires_company_selection?(user),
          requires_location_selection: requires_location_selection?(user)
        }, status: :ok
      rescue MfaService::InvalidCodeError => e
        render json: {
          success: false,
          error: e.message
        }, status: :unprocessable_entity
      rescue StandardError => e
        Rails.logger.error("MFA verification error: #{e.message}")
        Rails.logger.error(e.backtrace.join("\n"))
        render json: {
          success: false,
          error: 'Verification failed. Please try again.'
        }, status: :internal_server_error
      end

      # GET /api/auth/mfa/settings
      # Get MFA settings for authenticated user
      def settings
        user = current_user
        
        render json: {
          mfa_enabled: user.mfa_enabled || false,
          mfa_method: user.mfa_method || 'email',
          has_email: user.email.present?,
          has_phone: extract_phone(user).present?
        }, status: :ok
      end

      # PATCH /api/auth/mfa/toggle
      # Enable or disable MFA for authenticated user
      def toggle
        user = current_user
        enabled = params[:enabled]

        if enabled.nil?
          render json: {
            success: false,
            error: 'Enabled parameter is required'
          }, status: :bad_request
          return
        end

        # Convert to boolean
        enabled = ActiveModel::Type::Boolean.new.cast(enabled)

        # Update MFA settings
        user.update!(
          mfa_enabled: enabled,
          mfa_method: params[:method] || user.mfa_method || 'email'
        )

        render json: {
          success: true,
          message: enabled ? 'MFA has been enabled' : 'MFA has been disabled',
          mfa_enabled: user.mfa_enabled,
          mfa_method: user.mfa_method
        }, status: :ok
      rescue StandardError => e
        Rails.logger.error("MFA toggle error: #{e.message}")
        render json: {
          success: false,
          error: 'Failed to update MFA settings'
        }, status: :internal_server_error
      end

      private

      def find_user_by_id(user_id, user_type)
        if user_type == 'client'
          BuyerPortalAccess.find_by(id: user_id)
        else
          User.find_by(id: user_id)
        end
      end

      def extract_phone(user)
        if user.respond_to?(:phone)
          user.phone
        elsif user.is_a?(BuyerPortalAccess) && user.buyer.respond_to?(:phone)
          user.buyer.phone
        end
      end

      def generate_auth_token(user)
        if user.is_a?(BuyerPortalAccess)
          # For portal users, use basic encode since they don't have standard user fields
          JsonWebToken.encode(buyer_portal_access_id: user.id)
        else
          # For regular users, use the full access token generator
          JsonWebToken.generate_access_token(user)
        end
      end

      def serialize_user(user, user_type)
        if user.is_a?(BuyerPortalAccess)
          {
            id: user.id,
            account_id: user.buyer_id || 1,
            first_name: user.buyer&.first_name,
            last_name: user.buyer&.last_name,
            email: user.email,
            phone: user.buyer&.phone,
            status: user.portal_enabled ? 'active' : 'inactive',
            created_at: user.created_at&.iso8601,
            updated_at: user.updated_at&.iso8601,
            user_type: 'client'
          }
        else
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
            # Location assignments for location-tier users
            user_tier: location_data[:user_tier],
            location_ids: location_data[:location_ids],
            location_role: location_data[:location_role],
            assigned_locations: location_data[:assigned_locations],
            # Company subscription and module access
            company: build_company_data(user, company)
          }
        end
      end
      
      # Build location data for user response
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
          is_company_tier = user.company_admin? || user.roles_for_company(company&.id).any? { |r| r.tier == 'company' }
          
          {
            user_tier: is_company_tier ? 'company' : 'location',
            location_ids: [],
            location_role: nil,
            assigned_locations: []
          }
        end
      end
      
      # Build permissions array for frontend
      def build_permissions(user, company)
        return ['*:*:*'] if user.platform_admin? || user.super_admin?
        return ['*:*:*'] unless company&.use_rbac_system
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
      
      # Match login controller's user type detection
      def determine_user_type(user)
        return 'platform_admin' if user.platform_admin?
        return 'super_admin' if user.super_admin?
        return 'company_admin' if user.company_admin?
        return 'admin' if user.admin?
        return 'client' if user.client?
        return 'staff' if user.staff?
        'staff'
      end
      
      # Check if user needs to select a company (platform admins only)
      def requires_company_selection?(user)
        return false if user.is_a?(BuyerPortalAccess)
        user.platform_admin? || user.super_admin?
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
      
      # Check if user needs to select a location (multi-location users)
      def requires_location_selection?(user)
        return false if user.is_a?(BuyerPortalAccess)
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
    end
  end
end
