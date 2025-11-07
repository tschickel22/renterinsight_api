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
            user: {
              id: user.id,
              email: user.email,
              firstName: user.first_name,
              lastName: user.last_name,
              user_type: determine_user_type(user),
              role: user.role,
              company_id: user.company_id,
              permissions: user.permissions || []
            }
          }, status: :ok
        else
          render json: {
            success: false,
            message: 'Invalid email or password'
          }, status: :unauthorized
        end
      rescue StandardError => e
        Rails.logger.error("Login error: #{e.message}")
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
          user: {
            id: current_user.id,
            email: current_user.email,
            firstName: current_user.first_name,
            lastName: current_user.last_name,
            user_type: determine_user_type(current_user),
            role: current_user.role,
            company_id: current_user.company_id
          }
        }, status: :ok
      end

      # GET /api/auth/me
      def me
        render json: {
          success: true,
          user: {
            id: current_user.id,
            email: current_user.email,
            firstName: current_user.first_name,
            lastName: current_user.last_name,
            user_type: determine_user_type(current_user),
            role: current_user.role,
            company_id: current_user.company_id,
            permissions: current_user.permissions || []
          }
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

      # Removed generate_access_token and generate_refresh_token methods
      # Now using JsonWebToken.generate_token_pair for consistency

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
        return 'admin' if user.respond_to?(:admin?) && user.admin?
        return 'admin' if user.role == 'admin' || user.role == 'super_admin'
        return 'client' if user.respond_to?(:client?) && user.client?
        return 'client' if user.role == 'client' || user.role == 'buyer'
        return 'staff' if user.respond_to?(:staff?) && user.staff?
        return 'staff' if user.role == 'staff' || user.role == 'employee'

        'staff'
      end
    end
  end
end
