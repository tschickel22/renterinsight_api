# frozen_string_literal: true

module Api
  module Platform
    class CommunicationsController < ApplicationController
      before_action :set_entity, only: [:history]

      # GET /api/platform/communications/:entity_type/:entity_id/history
      def history
        communications = Communication
          .where(communicable_type: @entity_type, communicable_id: @entity_id)
          .order(created_at: :desc)
        
        render json: communications.map { |comm| comm_log_json(comm) }, status: :ok
      end

      # POST /api/platform/communications/email
      def email
        result = send_email_unified
        
        if result[:success]
          render json: result, status: result[:id] ? :created : :ok
        else
          render json: result, status: :unprocessable_entity
        end
      end

      # POST /api/platform/communications/sms
      def sms
        result = send_sms_unified
        
        if result[:success]
          render json: result, status: result[:id] ? :created : :ok
        else
          render json: result, status: :unprocessable_entity
        end
      end

      private

      def set_entity
        @entity_type = params[:entity_type]
        @entity_id = params[:entity_id]
        
        # Validate entity exists
        entity_class = @entity_type.constantize rescue nil
        unless entity_class
          render json: { error: "Invalid entity type: #{@entity_type}" }, status: :bad_request
          return
        end
        
        @entity = entity_class.find_by(id: @entity_id)
        unless @entity
          render json: { error: "#{@entity_type} not found" }, status: :not_found
        end
      rescue => e
        render json: { error: e.message }, status: :bad_request
      end

      def send_email_unified
        # Get settings
        settings = get_effective_settings
        email_config = settings.dig(:communications, :email) || settings.dig('communications', 'email') || {}
        
        Rails.logger.info "[Platform::CommunicationsController#email] Email config keys: #{email_config.keys}"
        
        unless email_configured?(email_config)
          return { 
            ok: false, 
            success: false,
            error: 'Email is not configured. Please configure email settings in Platform Settings.'
          }
        end

        # Decrypt settings like password reset does
        email_config = decrypt_settings(email_config)

        # Extract parameters
        email_params = extract_email_params
        
        # Configure ActionMailer like password reset does
        configure_action_mailer_smtp(email_config)
        
        # Send email via ActionMailer
        send_result = send_email_via_action_mailer(email_params, email_config)
        
        unless send_result[:success]
          return {
            ok: false,
            success: false,
            error: send_result[:error] || 'Failed to send email'
          }
        end

        # Create communication log if entity is provided
        entity_type = params[:entity_type]
        entity_id = params[:entity_id]
        
        if entity_type.present? && entity_id.present?
          entity = entity_type.constantize.find_by(id: entity_id)
          
          if entity
            log = Communication.create!(
              communicable: entity,
              channel: 'email',
              direction: 'outbound',
              subject: email_params[:subject],
              body: email_params[:content],
              status: 'sent',
              sent_at: Time.current,
              to_address: email_params[:to],
              from_address: email_config['fromEmail'] || email_config[:fromEmail],
              metadata: {
                message_id: send_result[:message_id],
                provider: email_config['provider'] || email_config[:provider] || 'smtp',
                template_id: email_params[:template_id]
              }.compact
            )

            return { 
              ok: true, 
              success: true,
              id: log.id,
              messageId: send_result[:message_id],
              provider: email_config['provider'] || email_config[:provider] || 'smtp'
            }
          end
        end

        # Test email without entity
        {
          ok: true, 
          success: true,
          message: 'Email sent successfully',
          messageId: send_result[:message_id],
          provider: email_config['provider'] || email_config[:provider] || 'smtp'
        }
      rescue => e
        Rails.logger.error("[Platform::CommunicationsController#email] Error: #{e.message}")
        Rails.logger.error(e.backtrace.first(5).join("\n"))
        {
          ok: false,
          success: false,
          error: e.message
        }
      end

      def send_sms_unified
        # Get settings
        settings = get_effective_settings
        sms_config = settings.dig(:communications, :sms) || settings.dig('communications', 'sms') || {}
        
        Rails.logger.info "[Platform::CommunicationsController#sms] SMS config: #{sms_config.keys}"
        
        unless sms_configured?(sms_config)
          return { 
            ok: false, 
            success: false,
            error: 'SMS is not configured. Please configure SMS settings in Platform Settings.'
          }
        end

        # Decrypt settings
        sms_config = decrypt_settings(sms_config)

        # Extract parameters
        sms_params = extract_sms_params
        
        # Send SMS via helper
        send_result = send_sms_via_provider(sms_params[:to], sms_params[:content], sms_config)
        
        unless send_result[:success]
          return {
            ok: false,
            success: false,
            error: send_result[:error] || 'Failed to send SMS'
          }
        end

        # Create communication log if entity is provided
        entity_type = params[:entity_type]
        entity_id = params[:entity_id]
        
        if entity_type.present? && entity_id.present?
          entity = entity_type.constantize.find_by(id: entity_id)
          
          if entity
            log = Communication.create!(
              communicable: entity,
              channel: 'sms',
              direction: 'outbound',
              body: sms_params[:content],
              status: 'sent',
              sent_at: Time.current,
              to_address: sms_params[:to],
              from_address: sms_config['fromNumber'] || sms_config[:fromNumber],
              metadata: {
                message_sid: send_result[:message_sid],
                provider: sms_config['provider'] || sms_config[:provider] || 'twilio',
                template_id: sms_params[:template_id]
              }.compact
            )

            return { 
              ok: true, 
              success: true,
              id: log.id,
              messageId: send_result[:message_sid],
              provider: sms_config['provider'] || sms_config[:provider] || 'twilio'
            }
          end
        end

        # Test SMS without entity
        {
          ok: true, 
          success: true,
          message: 'SMS sent successfully',
          messageId: send_result[:message_sid],
          provider: sms_config['provider'] || sms_config[:provider] || 'twilio'
        }
      rescue => e
        Rails.logger.error("[Platform::CommunicationsController#sms] Error: #{e.message}")
        Rails.logger.error(e.backtrace.first(5).join("\n"))
        {
          ok: false,
          success: false,
          error: e.message
        }
      end

      def get_effective_settings
        platform_settings = fetch_platform_settings
        company_settings = fetch_company_settings
        merge_settings(platform_settings, company_settings)
      rescue => e
        Rails.logger.error("[Platform::CommunicationsController] Error fetching settings: #{e.message}")
        {
          communications: {
            email: { isEnabled: false },
            sms: { isEnabled: false }
          }
        }
      end

      def fetch_platform_settings
        stored = Setting.get('Platform', 0, 'communications')
        return {} unless stored
        
        if stored.is_a?(Hash)
          { communications: stored }
        else
          {}
        end
      rescue => e
        Rails.logger.warn("[Platform::CommunicationsController] Could not fetch platform settings: #{e.message}")
        {}
      end

      def fetch_company_settings
        {}  # Can be implemented later if needed
      rescue => e
        Rails.logger.warn("[Platform::CommunicationsController] Could not fetch company settings: #{e.message}")
        {}
      end

      def merge_settings(platform, company)
        platform = platform.deep_symbolize_keys if platform.respond_to?(:deep_symbolize_keys)
        company = company.deep_symbolize_keys if company.respond_to?(:deep_symbolize_keys)
        
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

      def email_configured?(config)
        is_enabled = config[:isEnabled] || config['isEnabled']
        from_email = config[:fromEmail] || config['fromEmail']
        provider = config[:provider] || config['provider']
        smtp_host = config[:smtpHost] || config['smtpHost']
        
        is_enabled == true &&
        from_email.present? &&
        (provider.present? || smtp_host.present?)
      end

      def sms_configured?(config)
        is_enabled = config[:isEnabled] || config['isEnabled']
        from_number = config[:fromNumber] || config['fromNumber']
        provider = config[:provider] || config['provider']
        
        is_enabled == true &&
        from_number.present? &&
        provider.present?
      end

      def extract_email_params
        {
          subject: params[:subject],
          content: params[:body] || params[:html] || params[:content],
          to: params[:to],
          template_id: params[:template_id] || params[:templateId],
          cc: params[:cc],
          bcc: params[:bcc]
        }
      end

      def extract_sms_params
        {
          content: params[:message] || params[:content] || params[:body],
          to: params[:to],
          template_id: params[:template_id] || params[:templateId]
        }
      end

      # Configure ActionMailer SMTP like password reset does
      def configure_action_mailer_smtp(email_settings)
        return unless (email_settings['provider'] || email_settings[:provider]) == 'smtp'

        smtp_config = {
          address: email_settings['smtpHost'] || email_settings[:smtpHost] || 'smtp.gmail.com',
          port: (email_settings['smtpPort'] || email_settings[:smtpPort] || 587).to_i,
          user_name: email_settings['smtpUsername'] || email_settings[:smtpUsername],
          password: email_settings['smtpPassword'] || email_settings[:smtpPassword],
          authentication: (email_settings['smtpAuthentication'] || email_settings[:smtpAuthentication] || 'plain').to_sym,
          enable_starttls_auto: email_settings['smtpEnableStarttls'].nil? ? true : email_settings['smtpEnableStarttls']
        }

        ActionMailer::Base.delivery_method = :smtp
        ActionMailer::Base.smtp_settings = smtp_config
        ActionMailer::Base.perform_deliveries = true
        ActionMailer::Base.raise_delivery_errors = true
        
        Rails.logger.info("📧 ActionMailer SMTP configured: #{smtp_config[:address]}:#{smtp_config[:port]} (user: #{smtp_config[:user_name]})")
      rescue StandardError => e
        Rails.logger.error("❌ Failed to configure ActionMailer: #{e.message}")
        Rails.logger.error(e.backtrace.first(5).join("\n"))
      end

      # Send email via ActionMailer like password reset does
      def send_email_via_action_mailer(email_params, config)
        from_email = config['fromEmail'] || config[:fromEmail]
        from_name = config['fromName'] || config[:fromName] || 'RenterInsight'
        
        Rails.logger.info "[send_email_via_action_mailer] Sending to #{email_params[:to]} from #{from_email}"
        
        mail = CommunicationMailer.send_communication(
          to: email_params[:to],
          subject: email_params[:subject],
          body: email_params[:content],
          from_email: from_email,
          from_name: from_name,
          cc: email_params[:cc],
          bcc: email_params[:bcc]
        )
        
        mail.deliver_now
        
        Rails.logger.info "[send_email_via_action_mailer] Success: #{mail.message_id}"
        { 
          success: true, 
          message_id: mail.message_id
        }
      rescue => e
        Rails.logger.error "[send_email_via_action_mailer] Exception: #{e.message}"
        Rails.logger.error(e.backtrace.first(5).join("\n"))
        { success: false, error: e.message }
      end

      def send_sms_via_provider(to, message, config)
        provider = (config['provider'] || config[:provider] || 'twilio').to_sym
        
        case provider
        when :twilio
          send_sms_via_twilio(to, message, config)
        else
          { success: false, error: "Unknown SMS provider: #{provider}" }
        end
      end

      def send_sms_via_twilio(to, message, config)
        require 'net/http'
        require 'uri'
        require 'json'
        
        account_sid = config['twilioAccountSid'] || config[:twilioAccountSid]
        auth_token = config['twilioAuthToken'] || config[:twilioAuthToken]
        from_number = config['fromNumber'] || config[:fromNumber]
        
        Rails.logger.info "[send_sms_via_twilio] Sending to #{to} from #{from_number}"
        
        uri = URI.parse("https://api.twilio.com/2010-04-01/Accounts/#{account_sid}/Messages.json")
        
        request = Net::HTTP::Post.new(uri)
        request.basic_auth(account_sid, auth_token)
        request.set_form_data(
          'From' => from_number,
          'To' => to,
          'Body' => message
        )
        
        response = Net::HTTP.start(uri.hostname, uri.port, use_ssl: true) do |http|
          http.request(request)
        end
        
        result = JSON.parse(response.body)
        
        if response.code.to_i == 201
          Rails.logger.info "[send_sms_via_twilio] Success: #{result['sid']}"
          { 
            success: true, 
            message_sid: result['sid'],
            status: result['status']
          }
        else
          Rails.logger.error "[send_sms_via_twilio] Error: #{result['message']}"
          { 
            success: false, 
            error: result['message'] || 'Twilio API error'
          }
        end
      rescue => e
        Rails.logger.error "[send_sms_via_twilio] Exception: #{e.message}"
        { success: false, error: e.message }
      end

      # Decrypt settings like password reset does
      def decrypt_settings(settings)
        decrypted = settings.deep_dup
        
        # Decrypt sensitive fields
        decrypted.each do |key, value|
          if value.is_a?(String) && value.start_with?('encrypted:')
            decrypted[key] = decrypt(value)
          end
        end
        
        decrypted
      end

      def decrypt(encrypted_value)
        return encrypted_value unless encrypted_value.start_with?('encrypted:')
        
        encrypted_data = encrypted_value.sub('encrypted:', '')
        secret_key = ENV['SETTINGS_ENCRYPTION_KEY'] || Rails.application.secret_key_base
        key = ActiveSupport::KeyGenerator.new(secret_key).generate_key('', 32)
        crypt = ActiveSupport::MessageEncryptor.new(key)
        
        crypt.decrypt_and_verify(encrypted_data)
      rescue StandardError => e
        Rails.logger.error("Failed to decrypt setting: #{e.message}")
        nil
      end

      def comm_log_json(comm)
        {
          id: comm.id,
          leadId: comm.communicable_id,
          entityId: comm.communicable_id,
          entityType: comm.communicable_type,
          type: comm.channel,
          direction: comm.direction,
          subject: comm.subject,
          content: comm.body,
          status: comm.status,
          sentAt: comm.sent_at&.iso8601,
          deliveredAt: comm.delivered_at&.iso8601,
          readAt: comm.read_at&.iso8601,
          metadata: comm.metadata || {},
          createdAt: comm.created_at&.iso8601,
          updatedAt: comm.updated_at&.iso8601
        }.compact
      end
    end
  end
end
