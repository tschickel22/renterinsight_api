# frozen_string_literal: true

module Api
  module V1
    class ContactCommunicationsController < ApplicationController
      include RbacAuthorization
      rbac_resource :communications,
        read_actions: [:index],
        create_actions: [:email, :sms, :log],
        update_actions: [],
        delete_actions: []

      before_action :set_contact

      # GET /api/v1/contacts/:contact_id/communications
      def index
        @communications = @contact.communications
                                   .order(created_at: :desc)
                                   .limit(100)

        render json: @communications.map { |comm| communication_json(comm) }
      rescue => e
        Rails.logger.error "Error in contact_communications#index: #{e.message}\n#{e.backtrace.join("\n")}"
        render json: { error: e.message }, status: :internal_server_error
      end

      # POST /api/v1/contacts/:contact_id/communications/email
      def email
        # Check if contact opted out
        if @contact.opt_out_email?
          render json: { ok: false, error: 'Contact has opted out of email communications' }, status: :unprocessable_entity
          return
        end

        # Check if contact has email
        if @contact.email.blank?
          render json: { ok: false, error: 'Contact has no email address' }, status: :unprocessable_entity
          return
        end

        # Send email via CommunicationService with user email connection waterfall
        company = @contact.company || @contact.account&.company
        
        result = CommunicationService.send_email(
          communicable: @contact,
          to: @contact.email,
          subject: params[:subject],
          body: params[:body],
          category: 'contacts',
          metadata: { contact_id: @contact.id },
          portal_visible: false,
          send_async: false,
          user: current_user  # USER EMAIL CONNECTION WATERFALL
        )

        if result[:success]
          render json: { 
            ok: true, 
            id: result[:communication]&.id,
            messageId: result[:message_id],
            provider: result[:provider] || 'smtp',
            userEmailConnection: current_user&.has_email_connection?
          }
        else
          render json: { ok: false, error: result[:error] }, status: :unprocessable_entity
        end
      rescue => e
        Rails.logger.error "Error sending email to contact: #{e.message}\n#{e.backtrace.join("\n")}"
        render json: { ok: false, error: e.message }, status: :internal_server_error
      end

      # POST /api/v1/contacts/:contact_id/communications/sms
      def sms
        if @contact.opt_out_sms?
          render json: { ok: false, error: 'Contact has opted out of SMS communications' }, status: :unprocessable_entity
          return
        end

        if @contact.phone.blank?
          render json: { ok: false, error: 'Contact has no phone number' }, status: :unprocessable_entity
          return
        end

        company = @contact.company || @contact.account&.company

        # Use CommunicationSettingsService for proper waterfall + MessagingServiceSid
        sms_cfg = CommunicationSettingsService.for_company(company).sms_config

        if sms_cfg[:sms_provisioning_mode] == 'disabled' || sms_cfg[:enabled] == false
          render json: { ok: false, error: 'SMS is not configured for this company' }, status: :unprocessable_entity
          return
        end

        result = TwilioSmsService.send(
          to:                    @contact.phone,
          body:                  params[:message] || params[:body],
          from_number:           sms_cfg[:from_number],
          account_sid:           sms_cfg[:twilio_account_sid],
          auth_token:            sms_cfg[:twilio_auth_token],
          messaging_service_sid: sms_cfg[:twilio_messaging_service_sid]
        )

        if result[:success]
          communication = @contact.communications.create!(
            channel:      'sms',
            direction:    'outbound',
            body:         params[:message] || params[:body],
            to_address:   @contact.phone,
            from_address: sms_cfg[:from_number],
            status:       'sent',
            sent_at:      Time.current,
            metadata: {
              message_sid:       result[:message_sid],
              sender_user_id:    current_user&.id,
              messaging_service: sms_cfg[:twilio_messaging_service_sid].present?
            }.compact
          )
          render json: { ok: true, id: communication.id, messageId: result[:message_sid], provider: 'twilio' }
        else
          render json: { ok: false, error: result[:error] }, status: :unprocessable_entity
        end
      rescue => e
        Rails.logger.error "Error sending SMS to contact: #{e.message}\n#{e.backtrace.join("\n")}"
        render json: { ok: false, error: e.message }, status: :internal_server_error
      end

      # POST /api/v1/contacts/:contact_id/communications/log
      def log
        communication = @contact.communications.create!(
          channel: params[:type] || 'note',
          direction: params[:direction] || 'outbound',
          subject: params[:subject],
          body: params[:content],
          status: params[:status] || 'sent',
          sent_at: params[:sent_at] || Time.current,
          metadata: params[:metadata]
        )

        render json: communication_json(communication), status: :created
      rescue => e
        Rails.logger.error "Error logging communication: #{e.message}"
        render json: { error: e.message }, status: :internal_server_error
      end

      private

      def set_contact
        # STRICT TENANT ISOLATION: Only find contacts within company
        # RBAC: Location-tier users only access contacts in their assigned locations
        @contact = if current_user.uses_rbac? && !current_user.effective_admin?
          location_ids = permission_service.accessible_location_ids
          if location_ids.any?
            # Include contacts in assigned locations OR unassigned contacts (NULL location_id)
            Contact.where(company_id: current_company_id)
                   .where("location_id IN (?) OR location_id IS NULL", location_ids)
                   .find(params[:contact_id])
          else
            Contact.where(company_id: current_company_id).find(params[:contact_id])
          end
        else
          Contact.where(company_id: current_company_id).find(params[:contact_id])
        end
      rescue ActiveRecord::RecordNotFound
        render json: { error: 'Contact not found or access denied' }, status: :not_found
      end

      def communication_json(comm)
        # Handle metadata - could be Hash, String (from JSONB column), or nil
        # This matches the pattern from Lead CommunicationsController
        metadata_obj = {}
        
        if comm.metadata.present?
          if comm.metadata.is_a?(Hash)
            metadata_obj = comm.metadata
          elsif comm.metadata.is_a?(String)
            # Try to parse as JSON first
            begin
              metadata_obj = JSON.parse(comm.metadata)
            rescue JSON::ParserError
              # If JSON parse fails, convert Ruby hash syntax to JSON
              begin
                # Replace Ruby syntax with JSON syntax
                json_str = comm.metadata.gsub(/:([\w_]+)=>/, '"\1":')  # :key=> to "key":
                                        .gsub(/=>/, ':')                   # => to :
                                        .gsub(/nil/, 'null')               # nil to null
                metadata_obj = JSON.parse(json_str)
              rescue => e
                Rails.logger.warn "Failed to parse metadata for communication #{comm.id}: #{e.message}"
                metadata_obj = {}
              end
            end
          end
        end
        
        {
          id: comm.id,
          contactId: comm.communicable_id,
          type: comm.channel,
          direction: comm.direction,
          subject: comm.subject,
          content: comm.body,
          body: comm.body,
          status: comm.status,
          sentAt: comm.sent_at,
          deliveredAt: comm.delivered_at,
          openedAt: comm.read_at,
          clickedAt: nil,
          createdAt: comm.created_at,
          metadata: metadata_obj  # Returns object, not string!
        }
      end

      def get_effective_communication_settings
        company_id = @contact.company_id || @contact.account&.company_id

        # Try company settings first
        company_settings = Setting.where(
          scope_type: 'Company',
          scope_id: company_id,
          key: 'communications'
        ).first&.value if company_id

        # Fall back to portfolio settings
        portfolio_settings = Setting.where(
          scope_type: nil,
          scope_id: nil,
          key: 'communications'
        ).first&.value

        settings = if company_settings.present?
          JSON.parse(company_settings).deep_symbolize_keys
        elsif portfolio_settings.present?
          JSON.parse(portfolio_settings).deep_symbolize_keys
        else
          { email: {}, sms: {} }
        end

        settings[:email] ||= {}
        settings[:sms] ||= {}

        settings
      end
    end
  end
end
