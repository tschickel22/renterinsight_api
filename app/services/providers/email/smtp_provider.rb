# SMTP email provider using ActionMailer's built-in SMTP support
# Configurable via CommunicationSettingsService (Company → Platform → ENV hierarchy)

module Providers
  module Email
    class SmtpProvider < BaseProvider
      def initialize(company: nil)
        @company = company
        
        # Get settings from Company → Platform → ENV hierarchy
        settings_service = company ? 
          CommunicationSettingsService.for_company(company) : 
          CommunicationSettingsService.platform
        
        email_config = settings_service.email_config
        
        @config = {
          address: email_config[:smtp_host],
          port: email_config[:smtp_port],
          domain: email_config[:smtp_domain],
          user_name: email_config[:smtp_username],
          password: email_config[:smtp_password],
          authentication: email_config[:smtp_authentication] || 'plain',
          enable_starttls_auto: true
        }
        
        log_info("Initialized with #{company ? "company #{company.id}" : "platform"} settings")
      end
      
      def send_message(to:, from:, subject:, body:, cc: nil, bcc: nil, reply_to: nil, metadata: {}, **options)
        require_config(:address, :port, :user_name, :password)
        
        log_info("="*80)
        log_info("SMTP EMAIL SEND ATTEMPT")
        log_info("To: #{to}")
        log_info("From: #{from}")
        log_info("Subject: #{subject}")
        log_info("CC: #{cc}") if cc.present?
        log_info("BCC: #{bcc}") if bcc.present?
        log_info("Reply-To: #{reply_to}") if reply_to.present?
        log_info("Body length: #{body.length} characters")
        log_info("SMTP Server: #{config[:address]}:#{config[:port]}")
        log_info("SMTP Username: #{config[:user_name]}")
        log_info("SMTP Authentication: #{config[:authentication]}")
        log_info("SMTP Domain: #{config[:domain]}")
        log_info("="*80)
        
        begin
          # Use ActionMailer to send
          message_id, delivery_result = send_via_action_mailer(
            to: to,
            from: from,
            subject: subject,
            body: body,
            cc: cc,
            bcc: bcc,
            reply_to: reply_to,
            options: options
          )
          
          log_info("✅ SMTP accepted email for delivery")
          log_info("Message-ID: #{message_id}")
          
          # delivery_result may be nil if send_via_action_mailer only returns message_id
          if delivery_result.present?
            log_info("SMTP Response: #{delivery_result[:response]}")
          end
          
          log_info("="*80)
          log_info("⚠️  NOTE: Email accepted by SMTP does NOT guarantee delivery!")
          log_info("Gmail may silently filter to spam or reject after acceptance.")
          log_info("Check: 1) Gmail Spam folder, 2) Gmail All Mail, 3) Gmail account security")
          log_info("="*80)
          
          success_result(
            external_id: message_id,
            details: {
              smtp_server: config[:address],
              port: config[:port],
              smtp_response: delivery_result&.dig(:response),
              accepted_at: Time.current.iso8601
            }
          )
        rescue => e
          log_error("❌ SMTP ERROR")
          log_error("Error Class: #{e.class}")
          log_error("Error Message: #{e.message}")
          log_error("Error Backtrace: #{e.backtrace.first(5).join('\n')}")
          log_error("="*80)
          raise SendError, "SMTP send failed: #{e.message}"
        end
      end
      
      def verify_configuration
        require_config(:address, :port, :user_name, :password)
        
        begin
          # Test SMTP connection
          Net::SMTP.start(
            config[:address],
            config[:port],
            config[:domain] || 'localhost',
            config[:user_name],
            config[:password],
            config[:authentication] || 'plain'
          ) do |smtp|
            log_info("SMTP configuration verified successfully")
          end
          true
        rescue => e
          log_error("SMTP configuration verification failed: #{e.message}")
          false
        end
      end
      
      private
      
      def send_via_action_mailer(to:, from:, subject:, body:, cc:, bcc:, reply_to:, options:)
        mail = Mail.new do
          from from
          to to
          cc cc if cc.present?
          bcc bcc if bcc.present?
          reply_to reply_to if reply_to.present?
          subject subject
          
          if body.include?('</html>') || body.include?('<html>')
            content_type 'text/html; charset=UTF-8'
            body body
          else
            content_type 'text/plain; charset=UTF-8'
            body body
          end
        end
        
        # Add custom headers if provided
        if options[:headers]
          options[:headers].each do |key, value|
            mail.header[key] = value
          end
        end
        
        # Configure delivery method
        mail.delivery_method :smtp, config
        
        # Send and return message ID
        mail.deliver!
        mail.message_id
      end
    end
  end
end
