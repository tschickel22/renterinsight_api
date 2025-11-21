# frozen_string_literal: true

module Api
  module Companies
    class UsersController < ApplicationController
      before_action :authenticate_user!
      before_action :set_company_and_verify_access
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
      def create
        service = InvitationService.new(
          invited_by: current_user,
          company: @company
        )
        
        recipient_name = params[:recipient_name] || params[:recipientName]
        delivery_method = params[:deliveryMethod] || params[:delivery_method] || 'email'
        
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
        # SECURITY: Prevent self-privilege escalation
        new_role = params[:user][:role] || params[:role]
        role_changed = new_role.present? && new_role != @user.role
        
        if role_changed && @user.id == current_user.id
          Rails.logger.warn "🚫 [SECURITY] User #{current_user.id} attempted to change their own role from '#{@user.role}' to '#{new_role}'"
          return render json: {
            success: false,
            error: 'You cannot change your own role. Please contact an administrator.'
          }, status: :forbidden
        end
        
        # SECURITY: Enforce role hierarchy - users can only assign roles at or below their level
        if role_changed && !can_assign_role?(new_role)
          Rails.logger.warn "🚫 [SECURITY] User #{current_user.id} (#{current_user.role}) attempted to assign role '#{new_role}' without sufficient privileges"
          return render json: {
            success: false,
            error: 'You do not have permission to assign this role.'
          }, status: :forbidden
        end
        
        if @user.update(user_params)
          # If role changed, update RBAC assignment
          if role_changed && @company.use_rbac_system
            @user.replace_rbac_role(
              new_role,
              company_id: @company.id,
              assigned_by: current_user
            )
            Rails.logger.info "✅ [UsersController] Updated RBAC role to '#{new_role}' for user #{@user.id}"
          end
          
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
        reason = params[:reason] || 'No reason provided'
        
        if @user.destroy
          render json: {
            success: true,
            message: 'User deleted successfully',
            reason: reason
          }, status: :ok
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
        invitation = @company.invitations.find_by(email: @user.email, status: 'pending')
        
        unless invitation
          return render json: { 
            success: false,
            error: 'No pending invitation found for this user' 
          }, status: :not_found
        end
        
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
      
      def set_company_and_verify_access
        requested_company_id = params[:company_id]
        
        if current_user.platform_admin? || current_user.super_admin?
          @company = ::Company.find_by(id: requested_company_id)
          unless @company
            render json: { success: false, error: 'Company not found' }, status: :not_found
            return
          end
          Rails.logger.info "✅ [Companies::UsersController] Platform admin accessing company #{@company.id}"
        else
          unless current_user.company_id.to_s == requested_company_id.to_s
            Rails.logger.error "🚫 [Companies::UsersController] User #{current_user.id} attempted to access company #{requested_company_id} but belongs to #{current_user.company_id}"
            render json: { success: false, error: 'Forbidden - Cannot access other company users' }, status: :forbidden
            return
          end
          
          @company = ::Company.find_by(id: current_user.company_id)
          unless @company
            render json: { success: false, error: 'Company not found' }, status: :not_found
            return
          end
        end
      end
      
      def set_user
        @user = @company.users.find_by(id: params[:id])
        unless @user
          render json: { success: false, error: 'User not found' }, status: :not_found
        end
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
      
      # Role hierarchy for permission checking
      # Higher number = higher privilege
      ROLE_HIERARCHY = {
        'platform_admin' => 100,
        'super_admin' => 100,
        'Company Administrator' => 50,
        'company_admin' => 50,
        'admin' => 50,
        'Company Manager' => 40,
        'company_manager' => 40,
        'manager' => 40,
        'Company Staff' => 30,
        'company_staff' => 30,
        'staff' => 30,
        'Read-Only User' => 10,
        'company_read_only' => 10,
        'read_only' => 10
      }.freeze
      
      def can_assign_role?(target_role)
        # Platform admins and super admins can assign any role
        return true if current_user.platform_admin? || current_user.super_admin?
        
        # Get current user's role level
        current_level = ROLE_HIERARCHY[current_user.role] || 0
        
        # Check RBAC roles if the user has them
        if @company&.use_rbac_system
          current_user.roles_for_company(@company.id).each do |role|
            role_level = ROLE_HIERARCHY[role.key] || ROLE_HIERARCHY[role.name] || 0
            current_level = [current_level, role_level].max
          end
        end
        
        # Get target role level
        target_level = ROLE_HIERARCHY[target_role] || 0
        
        # Users can only assign roles at or below their level
        # But they cannot assign their own level (prevents lateral escalation)
        current_level > target_level
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
          daysUntilExpiry: invitation.expires_at ? ((invitation.expires_at - Time.current) / 1.day).round : 0,
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
        
        if current_user
          result[:invitedBy] = {
            id: current_user.id,
            name: [current_user.first_name, current_user.last_name].compact.join(' '),
            email: current_user.email
          }
        end
        
        if @company
          result[:company] = {
            id: @company.id,
            name: @company.name
          }
        end
        
        result[:deletedAt] = user.deleted_at if user.respond_to?(:deleted_at)
        
        result
      end
    end
  end
end
