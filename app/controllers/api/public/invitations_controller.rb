# frozen_string_literal: true

module Api
  module Public
    class InvitationsController < ApplicationController
      # Public endpoints - no authentication required for invitation acceptance
      
      # GET /api/public/invitations/verify?token=xxx
      def verify_token
        token = params[:token]
        
        unless token.present?
          return render json: { 
            success: false,
            error: 'Invitation token is required' 
          }, status: :bad_request
        end
        
        user = User.find_by(invitation_token: token)
        
        unless user
          return render json: { 
            success: false,
            error: 'Invalid or expired invitation token' 
          }, status: :not_found
        end
        
        # Check if invitation has expired
        if user.invitation_expires_at && user.invitation_expires_at < Time.current
          return render json: { 
            success: false,
            error: 'This invitation has expired',
            expired: true
          }, status: :unprocessable_entity
        end
        
        # Check if already accepted
        if user.status == 'active'
          return render json: { 
            success: false,
            error: 'This invitation has already been accepted',
            already_accepted: true
          }, status: :unprocessable_entity
        end
        
        # Return user info for account setup
        render json: {
          success: true,
          user: {
            id: user.id,
            email: user.email,
            first_name: user.first_name,
            last_name: user.last_name,
            role: user.role,
            company_id: user.company_id,
            company_name: user.company&.name
          },
          token: token
        }
      end
      
      # POST /api/public/invitations/accept
      def accept
        token = params[:token]
        password = params[:password]
        password_confirmation = params[:password_confirmation]
        
        unless token.present?
          return render json: { 
            success: false,
            error: 'Invitation token is required' 
          }, status: :bad_request
        end
        
        unless password.present? && password_confirmation.present?
          return render json: { 
            success: false,
            error: 'Password and confirmation are required' 
          }, status: :bad_request
        end
        
        unless password == password_confirmation
          return render json: { 
            success: false,
            error: 'Passwords do not match' 
          }, status: :unprocessable_entity
        end
        
        user = User.find_by(invitation_token: token)
        
        unless user
          return render json: { 
            success: false,
            error: 'Invalid or expired invitation token' 
          }, status: :not_found
        end
        
        # Check if invitation has expired
        if user.invitation_expires_at && user.invitation_expires_at < Time.current
          return render json: { 
            success: false,
            error: 'This invitation has expired' 
          }, status: :unprocessable_entity
        end
        
        # Check if already accepted
        if user.status == 'active'
          return render json: { 
            success: false,
            error: 'This invitation has already been accepted' 
          }, status: :unprocessable_entity
        end
        
        # Update user with new password and activate account
        if user.update(
          password: password,
          password_confirmation: password_confirmation,
          status: 'active',
          invitation_token: nil,
          invitation_expires_at: nil
        )
          render json: {
            success: true,
            message: 'Account activated successfully',
            user: {
              id: user.id,
              email: user.email,
              first_name: user.first_name,
              last_name: user.last_name,
              role: user.role,
              company_id: user.company_id
            }
          }
        else
          render json: { 
            success: false,
            error: user.errors.full_messages.join(', ')
          }, status: :unprocessable_entity
        end
      end
    end
  end
end
