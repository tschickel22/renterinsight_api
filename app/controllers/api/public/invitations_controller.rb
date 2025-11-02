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
        
        # Return user info for account setup in format frontend expects
        response_data = {
          success: true,
          email: user.email,
          recipientName: [user.first_name, user.last_name].compact.join(' '),
          role: user.role,
          companyName: user.company&.name || 'Unknown Company',
          expiresAt: user.invitation_expires_at&.iso8601,
          isExpired: false,
          token: token
        }
        
        Rails.logger.info "[INVITATION VERIFY] Returning response: #{response_data.to_json}"
        
        render json: response_data
      end
      
      # POST /api/public/invitations/accept
      def accept
        token = params[:token]
        password = params[:password]
        password_confirmation = params[:password_confirmation] || params[:password] # Use password if confirmation not provided
        first_name = params[:firstName] || params[:first_name]
        last_name = params[:lastName] || params[:last_name]
        phone = params[:phone]
        
        unless token.present?
          return render json: { 
            success: false,
            error: 'Invitation token is required' 
          }, status: :bad_request
        end
        
        unless password.present?
          return render json: { 
            success: false,
            error: 'Password is required' 
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
        update_attrs = {
          password: password,
          password_confirmation: password_confirmation,
          status: 'active',
          invitation_token: nil,
          invitation_expires_at: nil
        }
        
        # Update name fields if provided
        update_attrs[:first_name] = first_name if first_name.present?
        update_attrs[:last_name] = last_name if last_name.present?
        update_attrs[:phone] = phone if phone.present?
        
        if user.update(update_attrs)
          # Generate JWT token for immediate login
          token = JsonWebToken.encode(
            user_id: user.id,
            email: user.email,
            company_id: user.company_id,
            role: user.role
          )
          
          render json: {
            success: true,
            message: 'Account activated successfully',
            token: token,
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
            error: user.errors.full_messages.join(', ')
          }, status: :unprocessable_entity
        end
      end
    end
  end
end
