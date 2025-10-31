# frozen_string_literal: true

module Api
  module Auth
    class TokensController < ApplicationController
      skip_before_action :authenticate, only: [:refresh]
      
      # POST /api/auth/tokens/refresh
      # Refresh an access token using a refresh token
      def refresh
        refresh_token = params[:refresh_token] || request.headers['X-Refresh-Token']
        
        unless refresh_token.present?
          return render json: {
            success: false,
            error: 'Refresh token is required'
          }, status: :bad_request
        end
        
        # Decode and validate refresh token
        decoded = JsonWebToken.decode(refresh_token)
        
        unless decoded && decoded[:type] == 'refresh'
          return render json: {
            success: false,
            error: 'Invalid or expired refresh token'
          }, status: :unauthorized
        end
        
        # Load user
        user = User.find_by(id: decoded[:user_id])
        
        unless user
          return render json: {
            success: false,
            error: 'User not found'
          }, status: :not_found
        end
        
        # Check if user is still active
        unless user.status == 'active'
          return render json: {
            success: false,
            error: 'User account is not active'
          }, status: :forbidden
        end
        
        # Generate new token pair
        tokens = JsonWebToken.generate_token_pair(user)
        
        render json: {
          success: true,
          access_token: tokens[:access_token],
          refresh_token: tokens[:refresh_token],
          expires_in: tokens[:expires_in],
          user: {
            id: user.id,
            email: user.email,
            name: user.name,
            role: user.role
          }
        }, status: :ok
        
      rescue StandardError => e
        Rails.logger.error("Token refresh failed: #{e.message}")
        Rails.logger.error(e.backtrace.first(5).join("\n"))
        
        render json: {
          success: false,
          error: 'Failed to refresh token'
        }, status: :internal_server_error
      end
      
      # POST /api/auth/tokens/validate
      # Validate current access token
      def validate
        user_data = {
          id: current_user.id,
          email: current_user.email,
          name: current_user.name,
          role: current_user.role
        }
        
        # Add company_id if user has one
        user_data[:company_id] = current_user.company_id if current_user.respond_to?(:company_id) && current_user.company_id.present?
        
        render json: {
          valid: true,
          user: user_data
        }, status: :ok
      end
      
      # DELETE /api/auth/tokens/logout
      # Logout (client-side should delete tokens)
      def logout
        # In a production system with token blacklisting, you would:
        # 1. Add the token to a blacklist/revocation list
        # 2. Store in Redis with expiry matching token expiry
        # For now, we'll just return success and let client delete tokens
        
        render json: {
          success: true,
          message: 'Logged out successfully'
        }, status: :ok
      end
    end
  end
end
