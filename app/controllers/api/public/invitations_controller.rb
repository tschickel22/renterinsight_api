# frozen_string_literal: true

module Api
  module Public
    class InvitationsController < ApplicationController
      # Public endpoints - no authentication required for invitation acceptance
      skip_before_action :authenticate, only: [:verify_token, :accept]
      
      # GET /api/public/invitations/verify?token=xxx
      def verify_token
        token = params[:token]
        
        unless token.present?
          return render json: { 
            success: false,
            error: 'Invitation token is required' 
          }, status: :bad_request
        end
        
        # Use InvitationService to verify the token
        service = InvitationService.new(invited_by: nil)
        result = service.verify_invitation(token)
        
        if result[:valid]
          invitation = result[:invitation]
          
          # Get company branding for portal display
          company_branding = nil
          if invitation.company
            # Get platform name from platform settings
            platform_name = begin
              general_settings = PlatformSetting.general
              general_settings['platformName'] || general_settings[:platformName]
            rescue StandardError => e
              Rails.logger.warn "[INVITATION VERIFY] PlatformSetting error: #{e.message}"
              nil
            end
            platform_name ||= 'Renter Insight DMS'
            
            # Get branding from company settings (stored as JSON)
            branding = invitation.company.branding_settings || {}
            
            Rails.logger.info "[INVITATION BRANDING] Company ID: #{invitation.company.id}, Branding: #{branding.inspect}"
            
            company_branding = {
              logo: branding['logo'],
              portalLogo: branding['portalLogo'],
              primaryColor: branding['primaryColor'] || '#3b82f6',
              secondaryColor: branding['secondaryColor'] || '#8b5cf6',
              fontFamily: branding['fontFamily'] || 'Inter',
              portalName: branding['portalName'] || 'Customer Portal',
              platformName: platform_name
            }
            
            Rails.logger.info "[INVITATION BRANDING] Sending to frontend: #{company_branding.inspect}"
          end
          
          # Return invitation info for account setup in format frontend expects
          response_data = {
            success: true,
            email: invitation.email,
            phone: invitation.phone,
            recipientName: invitation.recipient_name,
            role: invitation.role,
            companyName: invitation.company&.name,
            expiresAt: invitation.expires_at&.iso8601,
            message: invitation.message,
            invitationType: invitation.invitation_type,
            token: token,
            branding: company_branding
          }
          
          Rails.logger.info "[INVITATION VERIFY] Returning response with branding: #{response_data.to_json}"
          
          render json: response_data
        else
          render json: { 
            success: false,
            error: result[:error] || 'Invalid or expired invitation'
          }, status: :not_found
        end
      rescue InvitationService::InvitationNotFoundError => e
        render json: { 
          success: false,
          error: 'Invalid or expired invitation token' 
        }, status: :not_found
      rescue StandardError => e
        Rails.logger.error "[INVITATION VERIFY] Error: #{e.message}"
        Rails.logger.error e.backtrace.first(5).join("\n")
        
        render json: { 
          success: false,
          error: 'Failed to verify invitation' 
        }, status: :internal_server_error
      end
      
      # POST /api/public/invitations/accept?token=xxx
      def accept
        token = params[:token]
        
        unless token.present?
          return render json: { 
            success: false,
            error: 'Invitation token is required' 
          }, status: :bad_request
        end
        
        # Prepare user parameters
        user_params = {
          first_name: params[:firstName] || params[:first_name],
          last_name: params[:lastName] || params[:last_name],
          name: "#{params[:firstName]} #{params[:lastName]}".strip,
          password: params[:password],
          phone: params[:phone],
          company_name: params[:companyName] || params[:company_name],
          domain: params[:domain]
        }
        
        # Validate required fields
        unless user_params[:password].present?
          return render json: { 
            success: false,
            error: 'Password is required' 
          }, status: :bad_request
        end
        
        unless user_params[:first_name].present? && user_params[:last_name].present?
          return render json: { 
            success: false,
            error: 'First name and last name are required' 
          }, status: :bad_request
        end
        
        # Use InvitationService to accept the invitation
        service = InvitationService.new(invited_by: nil)
        result = service.accept_invitation(
          token: token,
          user_params: user_params,
          ip_address: request.remote_ip,
          user_agent: request.user_agent
        )
        
        if result[:success]
          user = result[:user]
          
          # CRITICAL DEBUG: Log what we're encoding in JWT
          Rails.logger.info "🔐 [JWT GENERATION] User ID: #{user.id}, Email: #{user.email}"
          Rails.logger.info "🔐 [JWT GENERATION] Company ID: #{user.company_id}, Role: #{user.role}"
          Rails.logger.info "🔐 [JWT GENERATION] Company Name: #{user.company&.name}"
          
          # Generate JWT token for immediate login
          jwt_token = JsonWebToken.encode(
            user_id: user.id,
            email: user.email,
            company_id: user.company_id,
            role: user.role
          )
          
          Rails.logger.info "🔐 [JWT GENERATED] Token created for company_id: #{user.company_id}"
          
          render json: {
            success: true,
            message: 'Account activated successfully',
            token: jwt_token,
            user: {
              id: user.id,
              email: user.email,
              firstName: user.first_name,
              lastName: user.last_name,
              role: user.role,
              companyId: user.company_id
            }
          }
        else
          render json: { 
            success: false,
            error: result[:error] || 'Failed to accept invitation'
          }, status: :unprocessable_entity
        end
      rescue InvitationService::InvitationNotFoundError => e
        render json: { 
          success: false,
          error: 'Invalid or expired invitation token' 
        }, status: :not_found
      rescue InvitationService::InvitationExpiredError => e
        render json: { 
          success: false,
          error: 'This invitation has expired' 
        }, status: :unprocessable_entity
      rescue InvitationService::InvitationAlreadyAcceptedError => e
        render json: { 
          success: false,
          error: 'This invitation has already been accepted' 
        }, status: :unprocessable_entity
      rescue StandardError => e
        Rails.logger.error "[INVITATION ACCEPT] Error: #{e.message}"
        Rails.logger.error e.backtrace.first(5).join("\n")
        
        render json: { 
          success: false,
          error: 'Failed to accept invitation' 
        }, status: :internal_server_error
      end
    end
  end
end
