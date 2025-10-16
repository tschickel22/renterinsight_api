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

          access_token = generate_access_token(user)
          refresh_token = generate_refresh_token(user)

          user.update(last_sign_in_at: Time.current)

          set_refresh_token_cookie(refresh_token)

          render json: {
            success: true,
            message: 'Login successful',
            token: access_token,
            refreshToken: refresh_token,
            user: {
              id: user.id,
              email: user.email,
              firstName: user.first_name,
              lastName: user.last_name,
              user_type: determine_user_type(user),
              role: user.role,
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
          decoded = JWT.decode(
            refresh_token,
            Rails.application.credentials.jwt_refresh_secret || ENV['JWT_REFRESH_SECRET'],
            true,
            { algorithm: 'HS256' }
          )[0]

          user = User.find(decoded['user_id'])

          if user.inactive? || user.suspended?
            render json: {
              success: false,
              message: 'Account is not active'
            }, status: :forbidden
            return
          end

          new_access_token = generate_access_token(user)

          render json: {
            success: true,
            token: new_access_token
          }, status: :ok
        rescue JWT::DecodeError => e
          render json: {
            success: false,
            message: 'Invalid or expired refresh token'
          }, status: :unauthorized
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
            role: current_user.role
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
        begin
          decoded = JWT.decode(
            token,
            Rails.application.credentials.jwt_secret || ENV['JWT_SECRET'],
            true,
            { algorithm: 'HS256' }
          )[0]

          @current_user = User.find(decoded['user_id'])
        rescue JWT::DecodeError => e
          render json: {
            success: false,
            message: 'Invalid or expired token'
          }, status: :unauthorized
        rescue ActiveRecord::RecordNotFound
          render json: {
            success: false,
            message: 'User not found'
          }, status: :unauthorized
        end
      end

      def generate_access_token(user)
        payload = {
          user_id: user.id,
          email: user.email,
          user_type: determine_user_type(user),
          role: user.role,
          exp: 24.hours.from_now.to_i
        }

        JWT.encode(
          payload,
          Rails.application.credentials.jwt_secret || ENV['JWT_SECRET'],
          'HS256'
        )
      end

      def generate_refresh_token(user)
        payload = {
          user_id: user.id,
          email: user.email,
          exp: 7.days.from_now.to_i
        }

        JWT.encode(
          payload,
          Rails.application.credentials.jwt_refresh_secret || ENV['JWT_REFRESH_SECRET'],
          'HS256'
        )
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
