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

          set_refresh_token_cookie(tokens[:refresh_token])

          render json: {
            success: true,
            message: 'Login successful',
            token: tokens[:access_token],
            refreshToken: tokens[:refresh_token],
            user: build_user_response(user)
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
        
        {
          id: user.id,
          email: user.email,
          firstName: user.first_name,
          lastName: user.last_name,
          user_type: determine_user_type(user),
          role: user.role,
          company_id: user.company_id,
          companyName: company&.name,
          # RBAC information
          rbac_enabled: company&.use_rbac_system || false,
          permissions: build_permissions(user, company),
          roles: build_roles(user, company)
        }
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
    end
  end
end
