# frozen_string_literal: true
module Api
  module V1
    class AccountMessagesController < ApplicationController
      include RbacAuthorization
      rbac_resource :communications,
        read_actions: [:index],
        create_actions: [:create],
        update_actions: [],
        delete_actions: []

      before_action :set_company
      before_action :set_account

      # GET /api/v1/accounts/:account_id/messages
      def index
        # Get communications for this account using Phase 2 Communication model
        communications = Communication.where(communicable: @account)
                                     .order(created_at: :desc)
                                     .limit(100)
        
        render json: { messages: communications.map { |comm| message_json(comm) } }, status: :ok
      end

      # POST /api/v1/accounts/:account_id/messages
      def create
        message_type = params.dig(:message, :type) || params[:type]

        case message_type
        when 'email'
          send_email
        when 'sms'
          send_sms
        else
          render json: { error: 'Invalid message type' }, status: :unprocessable_entity
        end
      end

      private

      def set_company
        @company = ::Company.find_by(id: current_company_id)
        unless @company
          render json: { error: 'Company not found' }, status: :not_found
          return
        end
      end

      def set_account
        # TENANT ISOLATION: Only find accounts within the current company
        @account = @company.accounts.find_by(id: params[:account_id])
        unless @account
          Rails.logger.warn "[AccountMessagesController] Account #{params[:account_id]} not found in company #{@company.id}"
          render json: { error: 'Account not found or access denied', accountId: params[:account_id] }, status: :not_found
          return
        end
      end

      def send_email
        # Check if email is configured
        settings = get_effective_settings
        email_config = settings.dig(:communications, :email) || {}
        
        unless email_configured?(email_config)
          return render json: { 
            ok: false, 
            error: 'Email is not configured. Please configure email settings in Platform or Company Settings.'
          }, status: :unprocessable_entity
        end

        # Extract email parameters
        email_params = extract_email_params

        # Create Communication using Phase 2 model
        communication = Communication.create!(
          communicable: @account,
          direction: 'outbound',
          channel: 'email',
          status: 'sent',
          subject: email_params[:subject],
          body: email_params[:content],
          from_address: email_config[:fromEmail] || 'noreply@renterinsight.com',
          to_address: email_params[:to],
          sent_at: Time.current,
          metadata: build_email_metadata(email_params, email_config)
        )

        render json: { 
          ok: true, 
          id: communication.id, 
          provider: email_config[:provider] || 'smtp',
          message: message_json(communication)
        }, status: :created
      rescue => e
        Rails.logger.error("[AccountMessagesController#send_email] Error: #{e.message}")
        Rails.logger.error(e.backtrace.join("\n"))
        render json: { 
          ok: false, 
          error: e.message
        }, status: :unprocessable_entity
      end

      def send_sms
        # Check if SMS is configured
        settings = get_effective_settings
        sms_config = settings.dig(:communications, :sms) || {}
        
        unless sms_configured?(sms_config)
          return render json: { 
            ok: false, 
            error: 'SMS is not configured. Please configure SMS settings in Platform or Company Settings.'
          }, status: :unprocessable_entity
        end

        # Extract SMS parameters
        sms_params = extract_sms_params

        # Create Communication using Phase 2 model
        communication = Communication.create!(
          communicable: @account,
          direction: 'outbound',
          channel: 'sms',
          status: 'sent',
          body: sms_params[:content],
          from_address: sms_config[:fromNumber] || '+1234567890',
          to_address: sms_params[:to],
          sent_at: Time.current,
          metadata: build_sms_metadata(sms_params, sms_config)
        )

        render json: { 
          ok: true, 
          id: communication.id, 
          provider: sms_config[:provider] || 'twilio',
          message: message_json(communication)
        }, status: :created
      rescue => e
        Rails.logger.error("[AccountMessagesController#send_sms] Error: #{e.message}")
        Rails.logger.error(e.backtrace.join("\n"))
        render json: { 
          ok: false, 
          error: e.message
        }, status: :unprocessable_entity
      end

      # Get effective communication settings with waterfall:
      # Location → Company → Platform
      def get_effective_settings
        platform_settings = fetch_platform_settings
        company_settings = fetch_company_settings
        location_settings = fetch_location_settings

        # Start with platform (lowest priority)
        result = platform_settings.deep_dup

        # Merge company (overrides platform)
        result = merge_settings(result, company_settings) if company_settings.present?

        # Merge location (overrides company)
        result = merge_settings(result, location_settings) if location_settings.present?

        result
      rescue => e
        Rails.logger.error("[AccountMessagesController] Error fetching settings: #{e.message}")
        {
          communications: {
            email: { isEnabled: false },
            sms: { isEnabled: false }
          }
        }
      end

      def fetch_platform_settings
        stored = Setting.get('Platform', 0, 'communications')
        return {} unless stored.is_a?(Hash)

        { communications: stored.deep_symbolize_keys }
      rescue => e
        Rails.logger.warn("[AccountMessagesController] Could not fetch platform settings: #{e.message}")
        {}
      end

      def fetch_company_settings
        return {} unless @company

        stored = Setting.get('Company', @company.id, 'communications')
        return {} unless stored.is_a?(Hash)

        { communications: stored.deep_symbolize_keys }
      rescue => e
        Rails.logger.warn("[AccountMessagesController] Could not fetch company settings: #{e.message}")
        {}
      end

      def fetch_location_settings
        location_id = Current.location_id
        return {} unless location_id.present?

        stored = Setting.get('Location', location_id, 'communications')
        return {} unless stored.is_a?(Hash)

        { communications: stored.deep_symbolize_keys }
      rescue => e
        Rails.logger.warn("[AccountMessagesController] Could not fetch location settings: #{e.message}")
        {}
      end

      def merge_settings(base, override)
        base = base.deep_symbolize_keys if base.respond_to?(:deep_symbolize_keys)
        override = override.deep_symbolize_keys if override.respond_to?(:deep_symbolize_keys)

        result = base.deep_dup

        if override.dig(:communications, :email)
          result[:communications] ||= {}
          result[:communications][:email] ||= {}
          result[:communications][:email] = result[:communications][:email].deep_merge(override[:communications][:email])
        end

        if override.dig(:communications, :sms)
          result[:communications] ||= {}
          result[:communications][:sms] ||= {}
          result[:communications][:sms] = result[:communications][:sms].deep_merge(override[:communications][:sms])
        end

        result
      end

      # Check if email is properly configured
      def email_configured?(config)
        is_enabled = config[:isEnabled] || config['isEnabled']
        from_email = config[:fromEmail] || config['fromEmail'] || config[:oauthEmail] || config['oauthEmail']
        provider = config[:provider] || config['provider']
        smtp_host = config[:smtpHost] || config['smtpHost']

        is_enabled == true &&
        from_email.present? &&
        (provider.present? || smtp_host.present?)
      end

      # Check if SMS is properly configured
      def sms_configured?(config)
        config[:isEnabled] == true &&
        config[:fromNumber].present? &&
        config[:provider].present?
      end

      # Extract email parameters from various possible formats
      def extract_email_params
        # Try nested :message -> :email structure
        if params[:message].present?
          data = params[:message]
          {
            subject: data[:subject],
            content: data[:body] || data[:content],
            to: data[:to] || @account&.email,
            template_id: data[:template_id] || data[:templateId]
          }
        else
          # Fall back to root-level parameters
          {
            subject: params[:subject],
            content: params[:body] || params[:content],
            to: params[:to] || @account&.email,
            template_id: params[:template_id] || params[:templateId]
          }
        end
      end

      # Extract SMS parameters
      def extract_sms_params
        # Try nested :message structure
        if params[:message].present?
          data = params[:message]
          {
            content: data[:message] || data[:content] || data[:body],
            to: data[:to] || @account&.phone,
            template_id: data[:template_id] || data[:templateId]
          }
        else
          # Fall back to root-level parameters
          {
            content: params[:message] || params[:content] || params[:body],
            to: params[:to] || @account&.phone,
            template_id: params[:template_id] || params[:templateId]
          }
        end
      end

      # Build email metadata
      def build_email_metadata(email_params, config = {})
        {
          provider: config[:provider] || 'smtp',
          template_id: email_params[:template_id],
          to: email_params[:to],
          from_email: config[:fromEmail],
          from_name: config[:fromName]
        }.compact
      end

      # Build SMS metadata
      def build_sms_metadata(sms_params, config = {})
        {
          provider: config[:provider] || 'twilio',
          template_id: sms_params[:template_id],
          to: sms_params[:to],
          character_count: sms_params[:content]&.length,
          from_number: config[:fromNumber]
        }.compact
      end

      # Consistent JSON serialization for Phase 2 Communication model
      def message_json(communication)
        {
          id: communication.id,
          accountId: communication.communicable_id,
          type: communication.channel, # 'email' or 'sms'
          direction: communication.direction,
          subject: communication.subject,
          content: communication.body,
          body: communication.body, # alias for compatibility
          message: communication.body, # alias for SMS
          status: communication.status,
          sentAt: communication.sent_at&.iso8601,
          deliveredAt: communication.delivered_at&.iso8601,
          metadata: communication.metadata || {},
          createdAt: communication.created_at&.iso8601,
          updatedAt: communication.updated_at&.iso8601
        }.compact
      end
    end
  end
end
