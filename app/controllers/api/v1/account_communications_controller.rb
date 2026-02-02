# frozen_string_literal: true

module Api
  module V1
    class AccountCommunicationsController < ApplicationController
      include RbacAuthorization
      rbac_resource :communications,
        read_actions: [:index],
        create_actions: [:email, :sms, :log],
        update_actions: [],
        delete_actions: []

      before_action :set_account

      # GET /api/v1/accounts/:account_id/communications
      def index
        @communications = @account.communications
                                  .order(created_at: :desc)
                                  .limit(100)

        render json: @communications.map { |comm| communication_json(comm) }
      rescue => e
        Rails.logger.error "Error in account_communications#index: #{e.message}\n#{e.backtrace.join("\n")}"
        render json: { error: e.message }, status: :internal_server_error
      end

      # POST /api/v1/accounts/:account_id/communications/email
      def email
        # Check if account has email
        recipient = params[:to] || @account.email
        if recipient.blank?
          render json: { ok: false, error: 'Account has no email address' }, status: :unprocessable_entity
          return
        end

        # Send email via CommunicationService with user email connection waterfall
        result = CommunicationService.send_email(
          communicable: @account,
          to: recipient,
          subject: params[:subject],
          body: params[:body],
          category: 'accounts',
          metadata: { account_id: @account.id },
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
        Rails.logger.error "Error sending email: #{e.message}\n#{e.backtrace.join("\n")}"
        render json: { ok: false, error: e.message }, status: :internal_server_error
      end

      # POST /api/v1/accounts/:account_id/communications/sms
      def sms
        # Check if account has phone
        if @account.phone.blank?
          render json: { ok: false, error: 'Account has no phone number' }, status: :unprocessable_entity
          return
        end

        # Get effective settings
        settings = get_effective_communication_settings

        unless settings[:sms][:is_enabled]
          render json: { ok: false, error: 'SMS is not configured' }, status: :unprocessable_entity
          return
        end

        # Create communication record
        communication = @account.communications.create!(
          channel: 'sms',
          direction: 'outbound',
          body: params[:message],
          to_address: params[:to] || @account.phone,
          from_address: settings[:sms][:from_number],
          status: 'pending',
          provider: settings[:sms][:provider]
        )

        # Send SMS via SmsService
        result = SmsService.send_sms(
          to: params[:to] || @account.phone,
          from: settings[:sms][:from_number],
          body: params[:message],
          company: @account.company
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
        Rails.logger.error "Error sending SMS: #{e.message}\n#{e.backtrace.join("\n")}"
        render json: { ok: false, error: e.message }, status: :internal_server_error
      end

      # POST /api/v1/accounts/:account_id/communications/log
      def log
        communication = @account.communications.create!(
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

      def set_account
        # STRICT TENANT ISOLATION: Only find accounts within company
        # RBAC: Location-tier users only access accounts in their assigned locations
        @account = if current_user.uses_rbac? && !current_user.effective_admin?
          location_ids = permission_service.accessible_location_ids
          if location_ids.any?
            # Include accounts in assigned locations OR unassigned accounts (NULL location_id)
            Account.where(company_id: current_company_id)
                   .where("location_id IN (?) OR location_id IS NULL", location_ids)
                   .find(params[:account_id])
          else
            Account.where(company_id: current_company_id).find(params[:account_id])
          end
        else
          Account.where(company_id: current_company_id).find(params[:account_id])
        end
      rescue ActiveRecord::RecordNotFound
        render json: { error: 'Account not found or access denied' }, status: :not_found
      end

      def communication_json(comm)
        {
          id: comm.id,
          accountId: comm.communicable_id,
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
        # Try company settings first
        company_settings = Setting.where(
          scope_type: 'Company',
          scope_id: @account.company_id,
          key: 'communications'
        ).first&.value

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

        # Ensure nested hashes exist
        settings[:email] ||= {}
        settings[:sms] ||= {}

        settings
      end
    end
  end
end
