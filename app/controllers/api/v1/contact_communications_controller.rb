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

        # Get effective settings
        settings = get_effective_communication_settings

        unless settings[:email][:is_enabled]
          render json: { ok: false, error: 'Email is not configured' }, status: :unprocessable_entity
          return
        end

        # Create communication record
        communication = @contact.communications.create!(
          channel: 'email',
          direction: 'outbound',
          subject: params[:subject],
          body: params[:body],
          to_address: @contact.email,
          from_address: settings[:email][:from_email],
          status: 'pending',
          provider: settings[:email][:provider]
        )

        # Send email via EmailService
        result = EmailService.send_email(
          to: @contact.email,
          from: settings[:email][:from_email],
          subject: params[:subject],
          body: params[:body],
          company: @contact.company || @contact.account&.company
        )

        if result[:success]
          communication.update!(
            status: 'sent',
            sent_at: Time.current,
            provider_message_id: result[:message_id],
            metadata: (communication.metadata || {}).merge(provider_response: result[:response])
          )
        else
          communication.update!(
            status: 'failed',
            metadata: (communication.metadata || {}).merge(error: result[:error])
          )
          render json: { ok: false, error: result[:error] }, status: :unprocessable_entity
          return
        end

        render json: { 
          ok: true, 
          id: communication.id,
          provider: settings[:email][:provider]
        }
      rescue => e
        Rails.logger.error "Error sending email to contact: #{e.message}\n#{e.backtrace.join("\n")}"
        render json: { ok: false, error: e.message }, status: :internal_server_error
      end

      # POST /api/v1/contacts/:contact_id/communications/sms
      def sms
        # Check if contact opted out
        if @contact.opt_out_sms?
          render json: { ok: false, error: 'Contact has opted out of SMS communications' }, status: :unprocessable_entity
          return
        end

        # Check if contact has phone
        if @contact.phone.blank?
          render json: { ok: false, error: 'Contact has no phone number' }, status: :unprocessable_entity
          return
        end

        # Get effective settings
        settings = get_effective_communication_settings

        unless settings[:sms][:is_enabled]
          render json: { ok: false, error: 'SMS is not configured' }, status: :unprocessable_entity
          return
        end

        # Create communication record
        communication = @contact.communications.create!(
          channel: 'sms',
          direction: 'outbound',
          body: params[:message],
          to_address: @contact.phone,
          from_address: settings[:sms][:from_number],
          status: 'pending',
          provider: settings[:sms][:provider]
        )

        # Send SMS via SmsService
        result = SmsService.send_sms(
          to: @contact.phone,
          from: settings[:sms][:from_number],
          body: params[:message],
          company: @contact.company || @contact.account&.company
        )

        if result[:success]
          communication.update!(
            status: 'sent',
            sent_at: Time.current,
            provider_message_id: result[:message_id],
            metadata: (communication.metadata || {}).merge(provider_response: result[:response])
          )
        else
          communication.update!(
            status: 'failed',
            metadata: (communication.metadata || {}).merge(error: result[:error])
          )
          render json: { ok: false, error: result[:error] }, status: :unprocessable_entity
          return
        end

        render json: { 
          ok: true, 
          id: communication.id,
          provider: settings[:sms][:provider]
        }
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
          metadata: comm.metadata
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
