module Api
  module Portal
    class AuthController < ApplicationController
      before_action :authenticate_portal_buyer!, only: [:profile]
      before_action :rate_limit_auth!, only: [:login, :request_magic_link, :request_reset]
      
      def login
        buyer_access = BuyerPortalAccess.find_by(email: params[:email]&.downcase)
        
        if buyer_access&.authenticate(params[:password]) && buyer_access.portal_enabled
          # Successful login - clear rate limit and record login
          Rails.cache.delete("auth_attempts:#{request.remote_ip}")
          buyer_access.record_login!(request.remote_ip)
          token = JsonWebToken.encode(buyer_portal_access_id: buyer_access.id)
          
          render json: {
            ok: true,
            token: token,
            buyer: buyer_profile(buyer_access)
          }, status: :ok
        else
          # Failed login - rate limit already incremented by before_action
          render json: {
            ok: false,
            error: 'Invalid email or password'
          }, status: :unauthorized
        end
      end
      
      def request_magic_link
        buyer_access = BuyerPortalAccess.find_by(email: params[:email]&.downcase)
        
        if buyer_access && buyer_access.portal_enabled
          buyer_access.generate_login_token
          BuyerPortalService.send_magic_link_email(buyer_access)
          
          render json: {
            ok: true,
            message: 'Magic link sent to your email'
          }, status: :ok
        else
          render json: {
            ok: true,
            message: 'If an account exists, a magic link has been sent'
          }, status: :ok
        end
      end
      
      def verify_magic_link
        buyer_access = BuyerPortalAccess.find_by(login_token: params[:token])
        
        if buyer_access&.login_token_valid? && buyer_access.portal_enabled
          buyer_access.record_login!(request.remote_ip)
          buyer_access.update!(login_token: nil, login_token_expires_at: nil)
          
          token = JsonWebToken.encode(buyer_portal_access_id: buyer_access.id)
          
          render json: {
            ok: true,
            token: token,
            buyer: buyer_profile(buyer_access)
          }, status: :ok
        else
          render json: {
            ok: false,
            error: 'Invalid or expired magic link'
          }, status: :unauthorized
        end
      end
      
      def request_reset
        buyer_access = BuyerPortalAccess.find_by(email: params[:email]&.downcase)
        
        if buyer_access
          buyer_access.generate_reset_token
          BuyerPortalService.send_password_reset_email(buyer_access)
        end
        
        render json: {
          ok: true,
          message: 'If an account exists, a password reset link has been sent'
        }, status: :ok
      end
      
      def reset_password
        buyer_access = BuyerPortalAccess.find_by(reset_token: params[:token])
        
        if buyer_access&.reset_token_valid?
          if buyer_access.update(
            password: params[:password],
            password_confirmation: params[:password_confirmation],
            reset_token: nil,
            reset_token_expires_at: nil
          )
            render json: {
              ok: true,
              message: 'Password reset successfully'
            }, status: :ok
          else
            render json: {
              ok: false,
              errors: buyer_access.errors.full_messages
            }, status: :unprocessable_entity
          end
        else
          render json: {
            ok: false,
            error: 'Invalid or expired reset token'
          }, status: :unauthorized
        end
      end
      
      def profile
        render json: {
          ok: true,
          buyer: buyer_profile(current_portal_buyer)
        }, status: :ok
      end
      
      private
      
      def buyer_profile(buyer_access)
        {
          id: buyer_access.id,
          email: buyer_access.email,
          buyer_type: buyer_access.buyer_type,
          buyer_id: buyer_access.buyer_id,
          last_login_at: buyer_access.last_login_at,
          email_opt_in: buyer_access.email_opt_in,
          sms_opt_in: buyer_access.sms_opt_in,
          marketing_opt_in: buyer_access.marketing_opt_in
        }
      end
      
      def rate_limit_auth!
        cache_key = "auth_attempts:#{request.remote_ip}"
        attempts = Rails.cache.read(cache_key) || 0
        
        # Block if we've already hit the limit
        if attempts >= 5
          render json: {
            ok: false,
            error: 'Too many attempts. Please try again in 15 minutes.'
          }, status: :too_many_requests
          return
        end
        
        # Increment after checking
        Rails.cache.write(cache_key, attempts + 1, expires_in: 15.minutes)
      end
    end
  end
end
