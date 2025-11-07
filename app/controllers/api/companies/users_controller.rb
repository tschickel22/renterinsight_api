# frozen_string_literal: true

module Api
  module Companies
    class UsersController < ApplicationController
      before_action :set_company
      before_action :set_user, only: [:show, :update, :destroy, :resend_invitation]
      
      # GET /api/companies/:company_id/users
      def index
        users = @company.users
        
        render json: {
          success: true,
          users: users.map { |user| serialize_user(user) }
        }
      end
      
      # GET /api/companies/:company_id/users/:id
      def show
        render json: {
          success: true,
          user: serialize_user(@user)
        }
      end
      
      # POST /api/companies/:company_id/users
      # POST /api/companies/:company_id/invitations (alias)
      def create
        # ✅ FIX: Use InvitationService to create proper invitations
        service = InvitationService.new(
          invited_by: current_user,
          company: @company
        )
        
        # Get recipient name
        recipient_name = params[:recipient_name] || params[:recipientName]
        
        # Determine delivery method
        delivery_method = params[:deliveryMethod] || params[:delivery_method] || 'email'
        
        # Create invitation via service
        result = service.create_invitation(
          invitation_type: 'company_user',
          email: params[:email],
          phone: params[:phone],
          recipient_name: recipient_name,
          role: params[:role] || 'staff',
          permissions: params[:permissions] || [],
          delivery_method: delivery_method,
          message: params[:message]
        )
        
        if result[:success]
          invitation = result[:invitation]
          
          # Get the placeholder user that was created
          @user = User.find_by(email: invitation.email)
          
          render json: {
            success: true,
            invitation: serialize_invitation(invitation),
            user: @user ? serialize_user(@user) : serialize_invitation(invitation),
            message: result[:message]
          }, status: :created
        else
          render json: { 
            success: false,
            error: result[:error]
          }, status: :unprocessable_entity
        end
      end
      
      # PATCH/PUT /api/companies/:company_id/users/:id
      def update
        # ✅ FIX: Always return {success: true, user: {...}} format
        if @user.update(user_params)
          render json: {
            success: true,
            user: serialize_user(@user),
            message: 'User updated successfully'
          }
        else
          render json: { 
            success: false,
            errors: @user.errors.full_messages,
            error: @user.errors.full_messages.join(', ')
          }, status: :unprocessable_entity
        end
      end
      
      # DELETE /api/companies/:company_id/users/:id
      def destroy
        # ✅ FIX: Explicitly return status: :ok to prevent Rails from returning 204 No Content
        reason = params[:reason] || 'No reason provided'
        
        if @user.destroy
          render json: {
            success: true,
            message: 'User deleted successfully',
            reason: reason
          }, status: :ok  # ← CRITICAL: Must explicitly set :ok, otherwise Rails returns 204 No Content
        else
          render json: { 
            success: false,
            errors: @user.errors.full_messages,
            error: @user.errors.full_messages.join(', ')
          }, status: :unprocessable_entity
        end
      end
      
      # POST /api/companies/:company_id/users/:id/resend_invitation
      def resend_invitation
        # ✅ FIX: Use InvitationService to resend invitations properly
        
        # Find the invitation for this user
        invitation = Invitation.find_by(email: @user.email, status: 'pending')
        
        unless invitation
          return render json: { 
            success: false,
            error: 'No pending invitation found for this user' 
          }, status: :not_found
        end
        
        # Use service to resend
        service = InvitationService.new(
          invited_by: current_user,
          company: @company
        )
        
        result = service.resend_invitation(invitation.id)
        
        if result[:success]
          render json: { 
            success: true,
            message: 'Invitation resent successfully',
            user: serialize_user(@user.reload),
            invitation: serialize_invitation(result[:invitation])
          }
        else
          render json: { 
            success: false,
            error: result[:error]
          }, status: :unprocessable_entity
        end
      rescue => e
        Rails.logger.error "Error in resend_invitation: #{e.message}"
        Rails.logger.error e.backtrace.join("\n")
        
        render json: { 
          success: false,
          error: 'Failed to resend invitation',
          details: e.message
        }, status: :internal_server_error
      end
      
      private
      
      def set_company
        @company = ::Company.find(params[:company_id])
      rescue ActiveRecord::RecordNotFound
        render json: { success: false, error: 'Company not found' }, status: :not_found
      end
      
      def set_user
        # All company users should have company_id
        @user = @company.users.find(params[:id])
      rescue ActiveRecord::RecordNotFound
        render json: { success: false, error: 'User not found' }, status: :not_found
      end
      
      def user_params
        params.require(:user).permit(
          :email,
          :first_name,
          :last_name,
          :phone,
          :role,
          :status,
          :title,
          :department
        )
      end
      
      def invitation_params
        # Map invitation-style params to user attributes
        permitted = params.permit(
          :email,
          :phone,
          :recipient_name,
          :recipientName,
          :role,
          :invitation_type,
          :invitationType,
          :delivery_method,
          :deliveryMethod,
          :message,
          permissions: []
        )
        
        # Map recipientName to first_name and last_name
        name = permitted[:recipient_name] || permitted[:recipientName]
        if name.present?
          parts = name.split(' ', 2)
          permitted[:first_name] = parts[0]
          permitted[:last_name] = parts[1] if parts.length > 1
        end
        
        # Clean up the hash
        permitted.except(:recipient_name, :recipientName, :invitation_type, :invitationType, :delivery_method, :deliveryMethod, :message, :permissions)
      end
      
      def serialize_invitation(invitation)
        {
          id: invitation.id,
          invitationType: invitation.invitation_type,
          email: invitation.email,
          phone: invitation.phone,
          status: invitation.status,
          role: invitation.role,
          recipientName: invitation.recipient_name,
          deliveryMethod: invitation.delivery_method,
          message: invitation.message,
          sentAt: invitation.sent_at&.iso8601,
          expiresAt: invitation.expires_at&.iso8601,
          acceptedAt: invitation.accepted_at&.iso8601,
          lastSentAt: invitation.last_sent_at&.iso8601,
          resendCount: invitation.resend_count,
          attempts: invitation.attempts,
          viewedAt: invitation.viewed_at&.iso8601,
          canResend: invitation.can_accept?,
          canRevoke: invitation.status == 'pending',
          isExpired: invitation.expired?,
          daysUntilExpiry: ((invitation.expires_at - Time.current) / 1.day).round,
          createdAt: invitation.created_at&.iso8601,
          updatedAt: invitation.updated_at&.iso8601,
          invitedBy: {
            id: invitation.invited_by.id,
            name: invitation.invited_by.name || invitation.invited_by.email,
            email: invitation.invited_by.email
          },
          company: invitation.company ? {
            id: invitation.company.id,
            name: invitation.company.name
          } : nil
        }
      end
      
      def serialize_user(user)
        result = {
          id: user.id,
          email: user.email,
          firstName: user.first_name,
          lastName: user.last_name,
          recipientName: [user.first_name, user.last_name].compact.join(' '),
          phone: user.phone,
          role: user.role || 'user',
          status: user.status || 'pending',
          title: user.title,
          department: user.department,
          invitationType: 'company_user',
          deliveryMethod: user.phone.present? ? 'both' : 'email',
          sentAt: user.created_at,
          lastSentAt: user.created_at,
          expiresAt: (user.created_at + 7.days).iso8601,
          resendCount: 0,
          acceptAttempts: 0,
          canResend: true,
          canRevoke: (user.status || 'pending') == 'pending',
          isExpired: false,
          daysUntilExpiry: 7,
          createdAt: user.created_at,
          updatedAt: user.updated_at
        }
        
        # Add invitedBy if current_user exists
        if current_user
          result[:invitedBy] = {
            id: current_user.id,
            name: [current_user.first_name, current_user.last_name].compact.join(' '),
            email: current_user.email
          }
        else
          result[:invitedBy] = {
            id: 1,
            name: 'Admin',
            email: 'admin@example.com'
          }
        end
        
        # Add company if @company is set
        if @company
          result[:company] = {
            id: @company.id,
            name: @company.name
          }
        end
        
        # Add deletedAt if the model supports it
        result[:deletedAt] = user.deleted_at if user.respond_to?(:deleted_at)
        
        result
      end
    end
  end
end
