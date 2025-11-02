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
        render json: serialize_user(@user)
      end
      
      # POST /api/companies/:company_id/users
      # POST /api/companies/:company_id/invitations (alias)
      def create
        # Handle both user-style params (wrapped) and invitation-style params (unwrapped)
        user_attributes = if params[:user].present?
          user_params
        else
          invitation_params
        end
        
        @user = @company.users.new(user_attributes)
        
        # Generate temporary password
        temp_password = SecureRandom.alphanumeric(12)
        @user.password = temp_password
        @user.password_confirmation = temp_password
        
        if @user.save
          # Send invitation email
          # TODO: Implement invitation email sending
          
          render json: {
            success: true,
            invitation: serialize_user(@user),
            user: serialize_user(@user),
            message: 'User invitation sent successfully'
          }, status: :created
        else
          render json: { 
            success: false,
            errors: @user.errors.full_messages,
            error: @user.errors.full_messages.join(', ')
          }, status: :unprocessable_entity
        end
      end
      
      # PATCH/PUT /api/companies/:company_id/users/:id
      def update
        if @user.update(user_params)
          render json: serialize_user(@user)
        else
          render json: { errors: @user.errors.full_messages }, status: :unprocessable_entity
        end
      end
      
      # DELETE /api/companies/:company_id/users/:id
      def destroy
        if @user.destroy
          head :no_content
        else
          render json: { errors: @user.errors.full_messages }, status: :unprocessable_entity
        end
      end
      
      # POST /api/companies/:company_id/users/:id/resend_invitation
      def resend_invitation
        # TODO: Implement resend invitation email
        
        render json: { message: 'Invitation sent successfully' }
      end
      
      private
      
      def set_company
        @company = ::Company.find(params[:company_id])
      rescue ActiveRecord::RecordNotFound
        render json: { error: 'Company not found' }, status: :not_found
      end
      
      def set_user
        @user = @company.users.find(params[:id])
      rescue ActiveRecord::RecordNotFound
        render json: { error: 'User not found' }, status: :not_found
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
