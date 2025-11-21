# frozen_string_literal: true

require 'cgi'

module Api
  module V1
    class PortalUsersController < ApplicationController
      include RbacAuthorization
      rbac_resource :portal,
        read_actions: [:index, :show, :stats],
        create_actions: [:create, :invite],
        update_actions: [:update, :password_reset],
        delete_actions: [:destroy]

      before_action :set_portal_user, only: [:show, :update, :destroy]

      # GET /api/v1/portal_users
      def index
        # STRICT TENANT ISOLATION: Only return portal users from current user's company
        # RBAC: Location-tier users only see portal users for contacts in their assigned locations
        @portal_users = if current_user.uses_rbac? && !current_user.effective_admin?
          location_ids = permission_service.accessible_location_ids
          if location_ids.any?
            # Include portal users for contacts in assigned locations OR unassigned contacts (NULL location_id)
            BuyerPortalAccess
              .includes(:buyer)
              .where(company_id: current_company_id, buyer_type: 'Contact')
              .joins("INNER JOIN contacts ON contacts.id = buyer_portal_accesses.buyer_id")
              .where("contacts.location_id IN (?) OR contacts.location_id IS NULL", location_ids)
              .order(created_at: :desc)
          else
            BuyerPortalAccess
              .includes(:buyer)
              .where(company_id: current_company_id)
              .order(created_at: :desc)
          end
        else
          BuyerPortalAccess
            .includes(:buyer)
            .where(company_id: current_company_id)
            .order(created_at: :desc)
        end

        # Apply filters
        @portal_users = @portal_users.where(status: params[:status]) if params[:status].present?
        @portal_users = @portal_users.where(role: params[:role]) if params[:role].present?
        
        # Apply search
        if params[:search].present?
          search_term = "%#{params[:search]}%"
          @portal_users = @portal_users.joins(:contact).where(
            'contacts.first_name ILIKE ? OR contacts.last_name ILIKE ? OR contacts.email ILIKE ?',
            search_term, search_term, search_term
          )
        end

        # Pagination
        page = (params[:page] || 1).to_i
        per_page = (params[:per_page] || 25).to_i
        per_page = 100 if per_page > 100 # Max 100 per page

        total_count = @portal_users.count
        @portal_users = @portal_users.offset((page - 1) * per_page).limit(per_page)

        render json: {
          users: @portal_users.map { |user| format_portal_user(user) },
          meta: {
            current_page: page,
            per_page: per_page,
            total_pages: (total_count.to_f / per_page).ceil,
            total_count: total_count
          }
        }
      end

      # GET /api/v1/portal_users/:id
      def show
        render json: { user: format_portal_user(@portal_user) }
      end

      # POST /api/v1/portal_users
      def create
        contact = Contact.find_by(id: params[:contact_id], company_id: current_company_id)
        
        unless contact
          return render json: { error: 'Contact not found' }, status: :not_found
        end

        # Check if portal access already exists
        existing_access = BuyerPortalAccess.find_by(
          buyer_id: contact.id,
          buyer_type: 'Contact',
          company_id: current_company_id
        )

        if existing_access
          return render json: { error: 'Portal access already exists for this contact' }, status: :unprocessable_entity
        end

        @portal_user = BuyerPortalAccess.new(
          buyer_id: contact.id,
          buyer_type: 'Contact',
          company_id: current_company_id,
          email: params[:email] || contact.email,
          role: params[:role] || 'Client',
          status: params[:status] || 'Active',
          permissions: params[:permissions] || ['view_quotes', 'accept_quotes', 'view_documents']
        )

        if @portal_user.save
          render json: { user: format_portal_user(@portal_user) }, status: :created
        else
          render json: { errors: @portal_user.errors.full_messages }, status: :unprocessable_entity
        end
      end

      # PATCH/PUT /api/v1/portal_users/:id
      def update
        update_params = {}
        update_params[:email] = params[:email] if params[:email].present?
        update_params[:role] = params[:role] if params[:role].present?
        update_params[:status] = params[:status] if params[:status].present?
        update_params[:permissions] = params[:permissions] if params[:permissions].present?

        if @portal_user.update(update_params)
          render json: { user: format_portal_user(@portal_user) }
        else
          render json: { errors: @portal_user.errors.full_messages }, status: :unprocessable_entity
        end
      end

      # DELETE /api/v1/portal_users/:id
      def destroy
        @portal_user.destroy
        head :no_content
      end

      # POST /api/v1/portal_users/invite
      def invite
        unless current_user
          return render json: { error: 'Unauthorized' }, status: :unauthorized
        end

        unless params[:contact_id].present?
          return render json: { error: 'contactId is required' }, status: :unprocessable_entity
        end

        # SECURITY: For portal invites, ALWAYS use user's JWT company_id
        # Never use X-Company-ID header - users can only invite to their own company
        @user_company_id = @current_company_id # From JWT, not header
        
        Rails.logger.info("Portal invite: Looking for contact_id=#{params[:contact_id]}, company_id=#{@user_company_id}")

        contact = Contact.find_by(id: params[:contact_id], company_id: @user_company_id)
        
        unless contact
          Rails.logger.error("Contact not found: id=#{params[:contact_id]}, company_id=#{@user_company_id}")
          return render json: { error: 'Contact not found' }, status: :not_found
        end

        unless contact.email.present?
          return render json: { error: 'Contact must have an email address' }, status: :unprocessable_entity
        end

        # Check if portal access already exists for this contact
        existing_access = BuyerPortalAccess.find_by(
          buyer_id: contact.id,
          buyer_type: 'Contact',
          company_id: @user_company_id
        )

        if existing_access && existing_access.status == 'Active'
          return render json: { error: 'Contact already has active portal access' }, status: :unprocessable_entity
        end

        # Check if email is already used by another portal user (globally)
        email_to_use = (params[:email] || contact.email).downcase
        email_conflict = BuyerPortalAccess.find_by(email: email_to_use)
        
        if email_conflict && email_conflict.id != existing_access&.id
          Rails.logger.error("Email conflict: #{email_to_use} already used by BuyerPortalAccess ##{email_conflict.id}")
          return render json: { 
            error: "The email #{email_to_use} is already registered to another portal user. Please use a different email address." 
          }, status: :unprocessable_entity
        end

        # Create or update portal access
        @portal_user = existing_access || BuyerPortalAccess.new(
          buyer_id: contact.id,
          buyer_type: 'Contact',
          company_id: @user_company_id
        )

        @portal_user.assign_attributes(
          email: email_to_use,
          role: params[:role] || 'Client',
          status: 'Pending',
          permissions: params[:permissions] || ['view_quotes', 'accept_quotes', 'view_documents'],
          invitation_sent_at: Time.current
        )

        if @portal_user.save
          # Send invitation via CommunicationService
          delivery_method = params[:deliveryMethod] || params[:delivery_method] || 'email'
          Rails.logger.info("📧 Delivery method selected: #{delivery_method}")
          
          email_sent = false
          sms_sent = false
          errors = []
          
          if delivery_method == 'email' || delivery_method == 'both'
            begin
              send_portal_invitation(@portal_user, contact)
              email_sent = true
              Rails.logger.info("✅ Email invitation sent successfully")
            rescue => e
              Rails.logger.error("❌ Email failed: #{e.message}")
              errors << "Email: #{e.message}"
            end
          end
          
          if delivery_method == 'sms' || delivery_method == 'both'
            begin
              send_portal_invitation_sms(@portal_user, contact)
              sms_sent = true
              Rails.logger.info("✅ SMS invitation sent successfully")
            rescue => e
              Rails.logger.error("❌ SMS failed: #{e.message}")
              Rails.logger.error(e.backtrace.first(5).join("\n"))
              errors << "SMS: #{e.message}"
            end
          end
          
          # Build response message
          messages = []
          messages << "Email sent" if email_sent
          messages << "SMS sent" if sms_sent
          message = messages.any? ? messages.join(" and ") : "Invitation created"
          message += " (with errors: #{errors.join(', ')})" if errors.any?
          
          render json: { 
            user: format_portal_user(@portal_user),
            message: message,
            email_sent: email_sent,
            sms_sent: sms_sent,
            errors: errors.any? ? errors : nil
          }, status: :created
        else
          Rails.logger.error("Failed to save portal user: #{@portal_user.errors.full_messages.join(', ')}")
          render json: { errors: @portal_user.errors.full_messages }, status: :unprocessable_entity
        end
      rescue StandardError => e
        Rails.logger.error("Portal invitation error: #{e.message}")
        Rails.logger.error(e.backtrace.join("\n"))
        render json: { error: "Failed to send invitation: #{e.message}" }, status: :internal_server_error
      end

      # POST /api/v1/portal_users/password_reset
      def password_reset
        unless params[:email].present?
          return render json: { error: 'Email is required' }, status: :unprocessable_entity
        end

        portal_user = BuyerPortalAccess.find_by(
          email: params[:email],
          company_id: current_company_id
        )

        unless portal_user
          return render json: { error: 'Portal user not found' }, status: :not_found
        end

        # Send password reset via CommunicationService
        send_password_reset(portal_user)
        
        render json: { message: 'Password reset email sent' }
      rescue StandardError => e
        Rails.logger.error("Password reset error: #{e.message}")
        render json: { error: "Failed to send password reset: #{e.message}" }, status: :internal_server_error
      end

      # GET /api/v1/portal_users/stats
      def stats
        portal_users = BuyerPortalAccess.where(company_id: current_company_id)

        render json: {
          total: portal_users.count,
          active: portal_users.where(status: 'Active').count,
          inactive: portal_users.where(status: 'Inactive').count,
          pending: portal_users.where(status: 'Pending').count,
          by_role: portal_users.group(:role).count
        }
      end

      private

      # Helper to get the correct company_id for sensitive operations
      # Uses JWT company_id if set (from invite), otherwise current_company_id
      def secure_company_id
        @user_company_id || current_company_id
      end

      def set_portal_user
        # STRICT TENANT ISOLATION: Only find portal users within company
        # RBAC: Location-tier users only access portal users for contacts in their assigned locations
        @portal_user = if current_user.uses_rbac? && !current_user.effective_admin?
          location_ids = permission_service.accessible_location_ids
          if location_ids.any?
            # Include portal users for contacts in assigned locations OR unassigned contacts (NULL location_id)
            BuyerPortalAccess
              .where(id: params[:id], company_id: current_company_id, buyer_type: 'Contact')
              .joins("INNER JOIN contacts ON contacts.id = buyer_portal_accesses.buyer_id")
              .where("contacts.location_id IN (?) OR contacts.location_id IS NULL", location_ids)
              .first
          else
            BuyerPortalAccess.find_by(id: params[:id], company_id: current_company_id)
          end
        else
          BuyerPortalAccess.find_by(id: params[:id], company_id: current_company_id)
        end

        unless @portal_user
          render json: { error: 'Portal user not found or access denied' }, status: :not_found
        end
      end

      def format_portal_user(portal_user)
        contact = portal_user.contact
        
        {
          id: portal_user.id,
          email: portal_user.email,
          firstName: contact&.first_name,
          lastName: contact&.last_name,
          name: contact ? "#{contact.first_name} #{contact.last_name}".strip : portal_user.email,
          phone: contact&.phone,
          role: portal_user.role || 'Client',
          status: portal_user.status || 'Pending',
          contactId: (portal_user.buyer_type == 'Contact' ? portal_user.buyer_id : nil),
          permissions: portal_user.permissions || [],
          lastLogin: portal_user.last_login_at,
          invitationSentAt: portal_user.invitation_sent_at,
          createdAt: portal_user.created_at,
          updatedAt: portal_user.updated_at
        }
      end

      def send_portal_invitation(portal_user, contact)
        # Use CommunicationService to send invitation
        recipient_name = "#{contact.first_name} #{contact.last_name}".strip
        recipient_name = contact.email if recipient_name.blank?

        # Generate invitation token
        portal_user.generate_invitation_token

        # Find portal invitation template
        template = CommunicationTemplate.find_by(
          template_type: 'portal_user_invitation',
          channel: 'email',
          company_id: secure_company_id
        )

        unless template
          Rails.logger.warn("No portal invitation template found, using default")
          template = create_default_portal_invitation_template
        end

        # Build template context with registration URL
        portal_base_url = ENV['PORTAL_URL'] || ENV['FRONTEND_URL'] || 'https://localhost:5173'
        registration_url = "#{portal_base_url}/client/register?token=#{portal_user.invitation_token}"
        
        # Load company directly
        company = ::Company.find(secure_company_id)
        
        # IMPORTANT: Set both portal_url and registration_url to registration page
        # This ensures templates using either variable work correctly
        template_context = {
          recipient_name: recipient_name,
          portal_url: registration_url,
          registration_url: registration_url,
          company_name: company.name
        }

        # Render the template
        rendered = template.render(template_context)

        # Send email via CommunicationService
        result = CommunicationService.send_email(
          communicable: contact,
          to: portal_user.email,
          subject: rendered[:subject],
          body: rendered[:body],
          category: 'transactional',
          portal_visible: false,
          skip_preference_check: true,
          metadata: {
            portal_user_id: portal_user.id,
            invitation_type: 'portal_user'
          }
        )

        if result[:success]
          Rails.logger.info("Portal invitation sent to #{portal_user.email}")
        else
          Rails.logger.error("Failed to send portal invitation: #{result[:error]}")
          raise Error, result[:error]
        end
      end

      def send_password_reset(portal_user)
        contact = portal_user.contact
        recipient_name = contact ? "#{contact.first_name} #{contact.last_name}".strip : portal_user.email
        recipient_name = portal_user.email if recipient_name.blank?

        # Find password reset template
        template = CommunicationTemplate.find_by(
          template_type: 'password_reset',
          company_id: current_company_id
        )

        unless template
          Rails.logger.warn("No password reset template found, using default")
          template = create_default_password_reset_template
        end

        # Generate password reset token
        portal_user.generate_reset_token
        
        # Load company directly
        company = ::Company.find(current_company_id)
        
        # Build template context
        portal_base_url = ENV['PORTAL_URL'] || ENV['FRONTEND_URL'] || 'https://localhost:5173'
        template_context = {
          recipient_name: recipient_name,
          reset_url: "#{portal_base_url}/client/reset-password/new?token=#{portal_user.reset_token}",
          company_name: company.name
        }

        # Render the template
        rendered = template.render(template_context)

        # Send email via CommunicationService
        result = CommunicationService.send_email(
          communicable: contact || portal_user,
          to: portal_user.email,
          subject: rendered[:subject],
          body: rendered[:body],
          category: 'transactional',
          portal_visible: false,
          skip_preference_check: true,
          metadata: {
            portal_user_id: portal_user.id,
            reset_type: 'password_reset'
          }
        )

        if result[:success]
          Rails.logger.info("Password reset sent to #{portal_user.email}")
        else
          Rails.logger.error("Failed to send password reset: #{result[:error]}")
          raise Error, result[:error]
        end
      end

      def send_portal_invitation_sms(portal_user, contact)
        Rails.logger.info("📱 Starting SMS invitation for contact #{contact.id}")
        
        recipient_name = "#{contact.first_name} #{contact.last_name}".strip
        recipient_name = contact.email if recipient_name.blank?

        # Get phone number from contact
        phone = contact.phone
        Rails.logger.info("📞 Contact phone: #{phone.inspect}")
        
        unless phone.present?
          error_msg = "No phone number for contact #{contact.id}, cannot send SMS"
          Rails.logger.error("❌ #{error_msg}")
          raise StandardError, error_msg
        end

        # Find SMS template or create default
        template = CommunicationTemplate.find_by(
          template_type: 'portal_user_invitation',
          channel: 'sms',
          company_id: secure_company_id
        )

        unless template
          Rails.logger.warn("⚠️ No SMS portal invitation template found, creating default")
          template = create_default_portal_invitation_sms_template
        end
        
        Rails.logger.info("📝 Using SMS template: #{template.name}")

        # Load company directly
        company = ::Company.find(secure_company_id)

        # Build template context
        portal_base_url = ENV['PORTAL_URL'] || ENV['FRONTEND_URL'] || 'https://localhost:5173'
        registration_url = "#{portal_base_url}/client/register?token=#{portal_user.invitation_token}"
        template_context = {
          recipient_name: recipient_name,
          portal_url: registration_url,
          registration_url: registration_url,
          company_name: company.name
        }
        
        Rails.logger.info("🔧 Template context: #{template_context.inspect}")

        # Render the template
        rendered = template.render(template_context)
        Rails.logger.info("✉️ SMS body: #{rendered[:body][0..100]}...") # First 100 chars

        # Send SMS via CommunicationService
        Rails.logger.info("🚀 Sending SMS to #{phone} via CommunicationService")
        
        result = CommunicationService.send_sms(
          communicable: contact,
          to: phone,
          body: rendered[:body],
          category: 'transactional',
          portal_visible: false,
          skip_preference_check: true,
          metadata: {
            portal_user_id: portal_user.id,
            invitation_type: 'portal_user'
          }
        )
        
        Rails.logger.info("📡 SMS result: #{result.inspect}")

        if result[:success]
          Rails.logger.info("✅ Portal invitation SMS sent successfully to #{phone}")
        else
          error_msg = result[:error] || 'Unknown error'
          Rails.logger.error("❌ Failed to send portal invitation SMS: #{error_msg}")
          raise StandardError, error_msg
        end
      end

      def create_default_portal_invitation_template
        CommunicationTemplate.create!(
          name: 'Portal Invitation (Auto-Generated)',
          template_type: 'portal_user_invitation',
          channel: 'email',
          subject: 'Welcome to {{company_name}} Portal',
          body: <<~TEXT,
            Hi {{recipient_name}},

            You've been invited to access the {{company_name}} client portal!

            Click here to create your account:
            {{registration_url}}

            This link will expire in 15 minutes.

            Best regards,
            {{company_name}}
          TEXT
          company_id: secure_company_id
        )
      end

      def create_default_password_reset_template
        CommunicationTemplate.create!(
          name: 'Password Reset (Auto-Generated)',
          template_type: 'password_reset',
          channel: 'email',
          subject: 'Reset Your Password',
          body: <<~TEXT,
            Hi {{recipient_name}},

            Click the link below to reset your password:

            {{reset_url}}

            Best regards,
            {{company_name}}
          TEXT
          company_id: current_company_id
        )
      end

      def create_default_portal_invitation_sms_template
        CommunicationTemplate.create!(
          name: 'Portal Invitation SMS (Auto-Generated)',
          template_type: 'portal_user_invitation',
          channel: 'sms',
          body: 'Hi {{recipient_name}}, you have been invited to {{company_name}} portal! Complete registration: {{registration_url}}',
          company_id: secure_company_id
        )
      end
    end
  end
end
