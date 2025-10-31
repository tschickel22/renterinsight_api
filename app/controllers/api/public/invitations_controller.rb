# frozen_string_literal: true

module Api
  module Public
    class InvitationsController < ApplicationController
      skip_before_action :authenticate, only: [:verify, :accept]
      
      # GET /api/public/invitations/verify?token=xxx
      def verify
        token = params[:token]
        
        unless token.present?
          return render json: {
            valid: false,
            error: 'Token is required'
          }, status: :bad_request
        end
        
        service = InvitationService.new(invited_by: nil)
        result = service.verify_invitation(token)
        
        if result[:valid]
          invitation = result[:invitation]
          
          render json: {
            valid: true,
            invitation: {
              id: invitation.id,
              invitationType: invitation.invitation_type,
              email: invitation.email,
              recipientName: invitation.recipient_name,
              companyName: invitation.company&.name,
              role: invitation.role,
              message: invitation.message,
              expiresAt: invitation.expires_at&.iso8601
            }
          }, status: :ok
        else
          render json: {
            valid: false,
            error: 'Invalid or expired invitation'
          }, status: :not_found
        end
      rescue InvitationService::InvitationNotFoundError => e
        render json: {
          valid: false,
          error: e.message
        }, status: :not_found
      rescue StandardError => e
        Rails.logger.error("Invitation verification failed: #{e.message}")
        render json: {
          valid: false,
          error: 'An error occurred while verifying the invitation'
        }, status: :internal_server_error
      end
      
      # POST /api/public/invitations/accept
      def accept
        token = params[:token]
        
        unless token.present?
          return render json: {
            success: false,
            error: 'Token is required'
          }, status: :bad_request
        end
        
        service = InvitationService.new(invited_by: nil)
        
        user_params = {
          name: params[:name],
          first_name: params[:first_name] || params[:firstName],
          last_name: params[:last_name] || params[:lastName],
          password: params[:password],
          company_name: params[:company_name] || params[:companyName],
          domain: params[:domain]
        }
        
        result = service.accept_invitation(
          token: token,
          user_params: user_params,
          ip_address: request.remote_ip,
          user_agent: request.user_agent
        )
        
        if result[:success]
          user = result[:user]
          invitation = result[:invitation]
          
          # Generate JWT token pair for immediate login
          tokens = JsonWebToken.generate_token_pair(user)
          
          # Build user response with both role and user_type for compatibility
          user_response = {
            id: user.id,
            email: user.email,
            name: user.name,
            firstName: user.first_name,
            lastName: user.last_name,
            role: user.role,
            user_type: user.role # Add user_type for AuthContext compatibility
          }
          
          # Add company_id if user has one
          user_response[:companyId] = user.company_id if user.respond_to?(:company_id) && user.company_id.present?
          
          render json: {
            success: true,
            message: 'Invitation accepted successfully',
            user: user_response,
            access_token: tokens[:access_token],
            refresh_token: tokens[:refresh_token],
            expires_in: tokens[:expires_in],
            invitation: {
              id: invitation.id,
              type: invitation.invitation_type
            }
          }, status: :ok
        else
          render json: {
            success: false,
            error: result[:error]
          }, status: :unprocessable_entity
        end
      rescue InvitationService::InvitationNotFoundError => e
        render json: {
          success: false,
          error: 'Invalid or expired invitation'
        }, status: :not_found
      rescue InvitationService::InvitationExpiredError => e
        render json: {
          success: false,
          error: 'This invitation has expired'
        }, status: :gone
      rescue InvitationService::InvitationAlreadyAcceptedError => e
        render json: {
          success: false,
          error: 'This invitation has already been accepted'
        }, status: :conflict
      rescue StandardError => e
        Rails.logger.error("Invitation acceptance failed: #{e.message}")
        Rails.logger.error(e.backtrace.first(5).join("\n"))
        
        render json: {
          success: false,
          error: e.message
        }, status: :internal_server_error
      end
    end
  end
end
