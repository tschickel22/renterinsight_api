module Api
  module Portal
    class AuthController < ApplicationController
      # Skip authentication for public endpoints
      skip_before_action :authenticate, only: [
        :login, 
        :request_magic_link, 
        :verify_magic_link, 
        :request_reset, 
        :reset_password,
        :verify_invitation,
        :complete_registration
      ]
      
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
          
          # Format response to match frontend expectations (success + user)
          user_data = buyer_profile(buyer_access).merge(user_type: 'client')
          
          render json: {
            success: true,
            token: token,
            user: user_data
          }, status: :ok
        else
          render json: {
            success: false,
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
      
      def verify_invitation
        buyer_access = BuyerPortalAccess.find_by(invitation_token: params[:token])
        
        Rails.logger.info "[PORTAL VERIFY] BuyerPortalAccess found: #{buyer_access.present?}, ID: #{buyer_access&.id}"
        Rails.logger.info "[PORTAL VERIFY] Company: #{buyer_access&.company.present?}, Company ID: #{buyer_access&.company_id}"
        
        if buyer_access&.invitation_token_valid?
          # Get first/last name from Contact if available
          first_name = buyer_access.buyer&.first_name
          last_name = buyer_access.buyer&.last_name
          
          # Get company branding with error handling
          company_branding = nil
          begin
            if buyer_access.company
              company = buyer_access.company
              
              # Get platform name from general settings
              platform_name = begin
                general_settings = PlatformSetting.general
                general_settings['platformName'] || general_settings[:platformName]
              rescue StandardError => e
                Rails.logger.warn "[PORTAL VERIFY] PlatformSetting error: #{e.message}"
                nil
              end
              platform_name ||= 'Renter Insight DMS'
              
              # Get branding from company settings (stored as JSON)
              branding = company.branding_settings || {}
              
              Rails.logger.info "[PORTAL VERIFY INVITATION] Company ID: #{company.id}, Branding: #{branding.inspect}"
              
              company_branding = {
                logo: branding['logo'],
                portalLogo: branding['portalLogo'],
                primaryColor: branding['primaryColor'] || '#3b82f6',
                secondaryColor: branding['secondaryColor'] || '#8b5cf6',
                fontFamily: branding['fontFamily'] || 'Inter',
                portalName: branding['portalName'] || 'Customer Portal',
                platformName: platform_name
              }
              
              Rails.logger.info "[PORTAL VERIFY INVITATION] Sending branding: #{company_branding.inspect}"
            else
              Rails.logger.warn "[PORTAL VERIFY INVITATION] No company found for BuyerPortalAccess ID: #{buyer_access.id}"
            end
          rescue StandardError => e
            Rails.logger.error "[PORTAL VERIFY INVITATION] Error loading branding: #{e.message}"
            Rails.logger.error e.backtrace.first(5).join("\n")
            # Continue without branding rather than failing the request
            company_branding = nil
          end
          
          render json: {
            ok: true,
            email: buyer_access.email,
            buyer_type: buyer_access.buyer_type,
            first_name: first_name,
            last_name: last_name,
            branding: company_branding
          }, status: :ok
        else
          render json: {
            ok: false,
            error: 'Invalid or expired invitation token'
          }, status: :unauthorized
        end
      rescue StandardError => e
        Rails.logger.error "[PORTAL VERIFY INVITATION] Unexpected error: #{e.message}"
        Rails.logger.error e.backtrace.first(10).join("\n")
        
        render json: {
          ok: false,
          error: 'An error occurred while verifying the invitation'
        }, status: :internal_server_error
      end
      
      def complete_registration
        buyer_access = BuyerPortalAccess.find_by(invitation_token: params[:token])
        
        if !buyer_access&.invitation_token_valid?
          return render json: {
            ok: false,
            error: 'Invalid or expired invitation token'
          }, status: :unauthorized
        end
        
        if params[:password] != params[:password_confirmation]
          return render json: {
            ok: false,
            error: 'Passwords do not match'
          }, status: :unprocessable_entity
        end
        
        begin
          buyer_access.accept_invitation!(
            params[:first_name],
            params[:last_name],
            params[:password]
          )
          
          # Generate JWT token for auto-login
          token = JsonWebToken.encode(buyer_portal_access_id: buyer_access.id)
          buyer_access.record_login!(request.remote_ip)
          
          render json: {
            ok: true,
            token: token,
            buyer: buyer_profile(buyer_access)
          }, status: :ok
        rescue ActiveRecord::RecordInvalid => e
          render json: {
            ok: false,
            error: e.message,
            errors: buyer_access.errors.full_messages
          }, status: :unprocessable_entity
        end
      end
      
      private
      
      def buyer_profile(buyer_access)
        {
          id: buyer_access.id,
          account_id: buyer_access.buyer_id || 1,
          first_name: buyer_access.buyer&.first_name,
          last_name: buyer_access.buyer&.last_name,
          email: buyer_access.email,
          phone: buyer_access.buyer&.phone,
          status: buyer_access.portal_enabled ? 'active' : 'inactive',
          created_at: buyer_access.created_at&.iso8601,
          updated_at: buyer_access.updated_at&.iso8601,
          buyer_type: buyer_access.buyer_type,
          buyer_id: buyer_access.buyer_id,
          last_login_at: buyer_access.last_login_at&.iso8601,
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
