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
        # Prioritize invitation-style params (unwrapped with recipientName)
        # over user-style params (wrapped in user: {})
        user_attributes = if params[:recipientName].present? || params[:recipient_name].present?
          invitation_params
        elsif params[:user].present?
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
          # Generate invitation token
          invitation_token = SecureRandom.urlsafe_base64(32)
          invitation_expires = 7.days.from_now
          
          # Store token in user record (you may need to add these fields to users table)
          @user.update(
            invitation_token: invitation_token,
            invitation_sent_at: Time.current,
            invitation_expires_at: invitation_expires
          )
          
          # Build invitation acceptance URL
          frontend_url = ENV['FRONTEND_URL'] || 'http://localhost:5173'
          invitation_url = "#{frontend_url}/invitations/accept?token=#{invitation_token}"
          
          # Send invitation based on delivery method
          begin
            delivery_method = params[:deliveryMethod] || params[:delivery_method] || 'email'
            
            # Prepare invitation data for template
            template_context = {
              recipient_name: [@user.first_name, @user.last_name].compact.join(' '),
              first_name: @user.first_name,
              last_name: @user.last_name,
              email: @user.email,
              phone: @user.phone,
              role: @user.role,
              role_name: @user.role.to_s.titleize,
              company_name: @company.name,
              invited_by: current_user ? current_user.name : 'Admin',
              invitation_url: invitation_url,
              invitation_token: invitation_token,
              invitation_expires: invitation_expires.strftime('%B %d, %Y at %I:%M %p'),
              days_until_expiry: 7,
              setup_instructions: 'Click the link above to set your password and access your account.',
              login_url: "#{frontend_url}/login"
            }
            
            # Find appropriate template
            email_template = CommunicationTemplate.find_by(
              template_type: 'company_user_invitation',
              channel: 'email',
              is_active: true
            )
            
            sms_template = CommunicationTemplate.find_by(
              template_type: 'company_user_invitation',
              channel: 'sms',
              is_active: true
            )
            
            # Send email invitation
            if (delivery_method == 'email' || delivery_method == 'both') && email_template
              CommunicationService.send_communication(
                communicable: @user,
                channel: 'email',
                to: @user.email,
                template: email_template,
                template_context: template_context,
                category: 'transactional',
                portal_visible: false,
                skip_preference_check: true
              )
            end
            
            # Send SMS invitation
            if (delivery_method == 'sms' || delivery_method == 'both') && @user.phone.present? && sms_template
              CommunicationService.send_communication(
                communicable: @user,
                channel: 'sms',
                to: @user.phone,
                template: sms_template,
                template_context: template_context,
                category: 'transactional',
                skip_preference_check: true
              )
            end
          rescue => e
            Rails.logger.error "Failed to send invitation: #{e.message}"
            Rails.logger.error e.backtrace.join("\n")
            # Don't fail the request if communication fails
          end
          
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
        # Check if user is still in pending/invited status
        unless ['pending', 'invited', 'inactive'].include?(@user.status)
          return render json: { 
            success: false,
            error: 'User has already accepted invitation' 
          }, status: :unprocessable_entity
        end
        
        # Generate new invitation token
        invitation_token = SecureRandom.urlsafe_base64(32)
        invitation_expires = 7.days.from_now
        
        # Update user with new token and timestamps
        @user.update!(
          invitation_token: invitation_token,
          invitation_sent_at: Time.current,
          invitation_expires_at: invitation_expires
        )
        
        # Build invitation acceptance URL
        frontend_url = ENV['FRONTEND_URL'] || 'http://localhost:5173'
        invitation_url = "#{frontend_url}/invitations/accept?token=#{invitation_token}"
        
        # Prepare invitation data for template
        template_context = {
          recipient_name: [@user.first_name, @user.last_name].compact.join(' '),
          first_name: @user.first_name,
          last_name: @user.last_name,
          email: @user.email,
          phone: @user.phone,
          role: @user.role,
          role_name: @user.role.to_s.titleize,
          company_name: @company.name,
          invited_by: current_user ? current_user.name : 'Admin',
          invitation_url: invitation_url,
          invitation_token: invitation_token,
          invitation_expires: invitation_expires.strftime('%B %d, %Y at %I:%M %p'),
          days_until_expiry: 7,
          setup_instructions: 'Click the link above to set your password and access your account.',
          login_url: "#{frontend_url}/login"
        }
        
        # Find appropriate templates
        email_template = CommunicationTemplate.find_by(
          template_type: 'company_user_invitation',
          channel: 'email',
          is_active: true
        )
        
        sms_template = CommunicationTemplate.find_by(
          template_type: 'company_user_invitation',
          channel: 'sms',
          is_active: true
        )
        
        # Determine delivery method (check params or default to both)
        delivery_method = params[:deliveryMethod] || params[:delivery_method] || 'both'
        
        sent_channels = []
        errors = []
        
        begin
          # Send email invitation
          if (delivery_method == 'email' || delivery_method == 'both') && email_template
            CommunicationService.send_communication(
              communicable: @user,
              channel: 'email',
              to: @user.email,
              template: email_template,
              template_context: template_context,
              category: 'transactional',
              portal_visible: false,
              skip_preference_check: true
            )
            sent_channels << 'email'
          end
        rescue => e
          Rails.logger.error "Failed to send email invitation: #{e.message}"
          errors << "Email: #{e.message}"
        end
        
        begin
          # Send SMS invitation
          if (delivery_method == 'sms' || delivery_method == 'both') && @user.phone.present? && sms_template
            CommunicationService.send_communication(
              communicable: @user,
              channel: 'sms',
              to: @user.phone,
              template: sms_template,
              template_context: template_context,
              category: 'transactional',
              skip_preference_check: true
            )
            sent_channels << 'sms'
          end
        rescue => e
          Rails.logger.error "Failed to send SMS invitation: #{e.message}"
          errors << "SMS: #{e.message}"
        end
        
        # Return response based on what was sent
        if sent_channels.any?
          render json: { 
            success: true,
            message: "Invitation resent successfully via #{sent_channels.join(' and ')}",
            user: serialize_user(@user.reload),
            sent_via: sent_channels,
            errors: errors.any? ? errors : nil
          }
        else
          render json: { 
            success: false,
            error: 'Failed to send invitation',
            details: errors
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
