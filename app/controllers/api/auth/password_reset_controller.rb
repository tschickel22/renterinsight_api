# frozen_string_literal: true

module Api
  module Auth
    class PasswordResetController < ApplicationController
      skip_before_action :authenticate, only: [:request_reset, :verify_token, :reset_password]

      # POST /api/auth/request_password_reset
      def request_reset
        service = PasswordResetService.new(
          ip_address: request.remote_ip,
          user_agent: request.user_agent
        )

        result = service.request_reset(
          email: params[:email],
          phone: params[:phone],
          delivery_method: params[:delivery_method],
          user_type: params[:user_type] || 'auto'
        )

        render json: result, status: :ok
      rescue PasswordResetService::RateLimitError => e
        render json: {
          success: false,
          error: e.message
        }, status: :too_many_requests
      rescue PasswordResetService::DeliveryDisabledError => e
        render json: {
          success: false,
          error: e.message
        }, status: :unprocessable_entity
      rescue PasswordResetService::DeliveryFailedError => e
        render json: {
          success: false,
          error: 'Failed to send reset instructions. Please try again.'
        }, status: :internal_server_error
      rescue StandardError => e
        Rails.logger.error("Password reset request error: #{e.message}")
        Rails.logger.error(e.backtrace.join("\n"))
        render json: {
          success: false,
          error: 'An error occurred. Please try again later.'
        }, status: :internal_server_error
      end

      # POST /api/auth/verify_reset_token
      def verify_token
        token = params[:token]

        if token.blank?
          render json: {
            valid: false,
            message: 'Token is required'
          }, status: :bad_request
          return
        end

        service = PasswordResetService.new
        result = service.verify_token(token: token)

        render json: result, status: :ok
      rescue StandardError => e
        Rails.logger.error("Token verification error: #{e.message}")
        render json: {
          valid: false,
          message: 'Invalid token'
        }, status: :unprocessable_entity
      end

      # POST /api/auth/reset_password
      def reset_password
        token = params[:token]
        new_password = params[:password] || params[:new_password]

        if token.blank?
          render json: {
            success: false,
            error: 'Token is required'
          }, status: :bad_request
          return
        end

        if new_password.blank?
          render json: {
            success: false,
            error: 'New password is required'
          }, status: :bad_request
          return
        end

        if new_password.length < 6
          render json: {
            success: false,
            error: 'Password must be at least 6 characters'
          }, status: :unprocessable_entity
          return
        end

        service = PasswordResetService.new(
          ip_address: request.remote_ip,
          user_agent: request.user_agent
        )

        result = service.reset_password(
          token: token,
          new_password: new_password
        )

        render json: result, status: :ok
      rescue PasswordResetService::UserNotFoundError => e
        render json: {
          success: false,
          error: 'Invalid or expired reset token'
        }, status: :unprocessable_entity
      rescue StandardError => e
        Rails.logger.error("Password reset error: #{e.message}")
        Rails.logger.error(e.backtrace.join("\n"))
        render json: {
          success: false,
          error: 'Failed to reset password. Please try again.'
        }, status: :internal_server_error
      end
    end
  end
end
