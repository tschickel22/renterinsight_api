# frozen_string_literal: true

module Providers
  module Email
    class SmtpProvider < BaseProvider
      def send_message(to:, from: nil, subject:, body:, cc: nil, bcc: nil, reply_to: nil, attachments: [], inline_images: [], content_type: 'text/html', **options)
        validate_config!

        # Use from parameter or fall back to config
        from_address = from || config[:from_email]
        from_name = config[:from_name] || 'Platform DMS'

        Rails.logger.info "📧 Sending email via SMTP to #{to} from #{from_address}"
        Rails.logger.info "📧 Reply-To: #{reply_to}" if reply_to.present?

        # Build the mail message
        mail = CommunicationMailer.send_communication(
          to: to,
          from_email: from_address,
          from_name: from_name,
          subject: subject,
          body: body,
          cc: cc,
          bcc: bcc,
          reply_to: reply_to,
          file_attachments: attachments,
          inline_images: inline_images,
          content_type: content_type
        )
        
        # CRITICAL: Set delivery method PER-MESSAGE (thread-safe)
        # Do NOT mutate global ActionMailer::Base.smtp_settings
        if smtp_configured?
          smtp_config = build_smtp_config
          mail.delivery_method(:smtp, smtp_config)
          Rails.logger.info "📧 Per-message SMTP configured: #{smtp_config[:address]}:#{smtp_config[:port]} (auth: #{smtp_config[:authentication]})"
        end
        
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
      
      def build_smtp_config
        {
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
      end
    end
  end
end
