# frozen_string_literal: true
module Api
  module V1
    class AccountMessagesController < ApplicationController
      before_action :set_account

      # GET /api/v1/accounts/:account_id/messages
      def index
        # Get communication logs for this account
        logs = CommunicationLog.for_account(@account.id).recent
        render json: { messages: logs.map { |log| message_json(log) } }, status: :ok
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

      def set_account
        @account = Account.find(params[:account_id])
      rescue ActiveRecord::RecordNotFound
        render json: { error: 'Account not found', accountId: params[:account_id] }, status: :not_found
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

        log = CommunicationLog.create!(
          account:    @account,
          comm_type:  'email',
          direction:  'outbound',
          subject:    email_params[:subject],
          content:    email_params[:content],
          status:     'sent',
          sent_at:    Time.current,
          metadata:   build_email_metadata(email_params, email_config)
        )

        render json: { 
          ok: true, 
          id: log.id, 
          provider: email_config[:provider] || 'smtp',
          message: message_json(log)
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

        log = CommunicationLog.create!(
          account:    @account,
          comm_type:  'sms',
          direction:  'outbound',
          content:    sms_params[:content],
          status:     'sent',
          sent_at:    Time.current,
          metadata:   build_sms_metadata(sms_params, sms_config)
        )

        render json: { 
          ok: true, 
          id: log.id, 
          provider: sms_config[:provider] || 'twilio',
          message: message_json(log)
        }, status: :created
      rescue => e
        Rails.logger.error("[AccountMessagesController#send_sms] Error: #{e.message}")
        Rails.logger.error(e.backtrace.join("\n"))
        render json: { 
          ok: false, 
          error: e.message
        }, status: :unprocessable_entity
      end

      # Get effective communication settings (company overrides platform)
      def get_effective_settings
        platform_settings = fetch_platform_settings
        company_settings = fetch_company_settings
        
        # Deep merge: company settings override platform settings
        merge_settings(platform_settings, company_settings)
      rescue => e
        Rails.logger.error("[AccountMessagesController] Error fetching settings: #{e.message}")
        # Return safe defaults
        {
          communications: {
            email: { isEnabled: false },
            sms: { isEnabled: false }
          }
        }
      end

      def fetch_platform_settings
        # Make internal request to platform settings
        response = Faraday.get("#{request.base_url}/api/platform/settings") rescue nil
        return {} unless response&.success?
        
        JSON.parse(response.body, symbolize_names: true) rescue {}
      rescue => e
        Rails.logger.warn("[AccountMessagesController] Could not fetch platform settings: #{e.message}")
        # Return default platform settings
        {
          communications: {
            email: {
              provider: 'smtp',
              fromEmail: 'platform@renterinsight.com',
              fromName: 'RenterInsight Platform',
              isEnabled: true
            },
            sms: {
              provider: 'twilio',
              fromNumber: '+1234567890',
              isEnabled: false
            }
          }
        }
      end

      def fetch_company_settings
        # Make internal request to company settings
        response = Faraday.get("#{request.base_url}/api/company/settings") rescue nil
        return {} unless response&.success?
        
        JSON.parse(response.body, symbolize_names: true) rescue {}
      rescue => e
        Rails.logger.warn("[AccountMessagesController] Could not fetch company settings: #{e.message}")
        {}
      end

      def merge_settings(platform, company)
        result = platform.deep_dup
        
        if company.dig(:communications, :email)
          result[:communications] ||= {}
          result[:communications][:email] ||= {}
          result[:communications][:email].merge!(company[:communications][:email])
        end
        
        if company.dig(:communications, :sms)
          result[:communications] ||= {}
          result[:communications][:sms] ||= {}
          result[:communications][:sms].merge!(company[:communications][:sms])
        end
        
        result
      end

      # Check if email is properly configured
      def email_configured?(config)
        config[:isEnabled] == true &&
        config[:fromEmail].present? &&
        (config[:provider].present? || config[:smtpHost].present?)
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

      # Consistent JSON serialization
      def message_json(log)
        {
          id: log.id,
          accountId: log.account_id,
          type: log.comm_type,
          direction: log.direction,
          subject: log.subject,
          content: log.content,
          body: log.content, # alias for compatibility
          message: log.content, # alias for SMS
          status: log.status,
          sentAt: log.sent_at&.iso8601,
          deliveredAt: log.delivered_at&.iso8601,
          metadata: log.metadata || {},
          createdAt: log.created_at&.iso8601,
          updatedAt: log.updated_at&.iso8601
        }.compact
      end
    end
  end
end
