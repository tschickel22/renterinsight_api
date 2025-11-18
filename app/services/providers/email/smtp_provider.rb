# frozen_string_literal: true

module Providers
  module Email
    class SmtpProvider < BaseProvider
      def send_message(to:, from: nil, subject:, body:, cc: nil, bcc: nil, reply_to: nil, attachments: [], **options)
        validate_config!
        
        # Use from parameter or fall back to config
        from_address = from || config[:from_email]
        from_name = config[:from_name] || 'Platform DMS'
        
        Rails.logger.info "📧 Sending email via SMTP to #{to} from #{from_address}"
        
        # Configure ActionMailer SMTP settings
        configure_smtp_settings if smtp_configured?
        
        # Use CommunicationMailer.send_communication (same as Platform test email)
        mail = CommunicationMailer.send_communication(
          to: to,
          from_email: from_address,
          from_name: from_name,
          subject: subject,
          body: body,
          cc: cc,
          bcc: bcc,
          file_attachments: attachments
        )
        
        result = mail.deliver_now
        
        Rails.logger.info "✅ SMTP email sent successfully: #{result.message_id}"
        
        {
          success: true,
          external_id: result.message_id,
          provider: 'smtp'
        }
      rescue StandardError => e
        Rails.logger.error "❌ SMTP delivery failed: #{e.message}"
        Rails.logger.error e.backtrace.first(5).join("\n")
        raise DeliveryError, "SMTP delivery failed: #{e.message}"
      end
      
      private
      
      def smtp_configured?
        config[:smtp_host].present? && config[:smtp_username].present?
      end
      
      def configure_smtp_settings
        smtp_config = {
          address: config[:smtp_host],
          port: config[:smtp_port] || 587,
          domain: config[:smtp_domain] || 'localhost',
          user_name: config[:smtp_username],
          password: config[:smtp_password],
          authentication: (config[:smtp_authentication] || 'plain').to_sym,
          enable_starttls_auto: true,
          open_timeout: 5,
          read_timeout: 10
        }.compact
        
        ActionMailer::Base.delivery_method = :smtp
        ActionMailer::Base.smtp_settings = smtp_config
        ActionMailer::Base.perform_deliveries = true
        ActionMailer::Base.raise_delivery_errors = true
        
        Rails.logger.info "📧 ActionMailer SMTP configured: #{smtp_config[:address]}:#{smtp_config[:port]}"
      rescue StandardError => e
        Rails.logger.error "❌ Failed to configure SMTP: #{e.message}"
        raise
      end
    end
  end
end
