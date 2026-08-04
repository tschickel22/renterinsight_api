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
        
        # A send-only Gmail grant cannot authenticate to SMTP at all: the server
        # answers the XOAUTH2 challenge with {"status":"400","scope":
        # "https://mail.google.com/"}. Same message, different transport.
        return deliver_via_gmail_api(mail) if config[:requires_rest_send]

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

      # ActionMailer never delivers this one; the fully rendered message goes to
      # Gmail's REST API instead, so attachments and inline images are identical
      # to the SMTP path.
      def deliver_via_gmail_api(mail)
        message = mail.message
        # Mail assigns a Message-ID lazily. Force it so external_id carries an
        # RFC Message-ID here exactly as it does on the SMTP path.
        message.message_id ||= Mail::MessageIdField.new.message_id

        result = GmailApiProvider.deliver_raw(
          raw_message:   message.to_s,
          access_token:  config[:oauth_access_token],
          refresh_token: config[:oauth_refresh_token],
          message_id:    message.message_id
        )

        # Raise rather than return a failure hash: callers already treat a
        # DeliveryError as the failure path, and CommunicationService's rescue
        # is what flags the connection as needing re-auth.
        raise DeliveryError, "Gmail API delivery failed: #{result[:error]}" unless result[:success]

        Rails.logger.info "✅ Gmail API email sent successfully: #{result[:message_id]}"
        {
          success: true,
          external_id: result[:message_id],
          provider: 'gmail_api'
        }
      end

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
