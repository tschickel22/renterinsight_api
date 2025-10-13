# SMTP email provider using ActionMailer's built-in SMTP support
# Configurable via environment variables or Rails config

module Providers
  module Email
    class SmtpProvider < BaseProvider
      def initialize
        @config = {
          address: ENV['SMTP_ADDRESS'] || Rails.application.config.action_mailer.smtp_settings[:address],
          port: ENV['SMTP_PORT'] || Rails.application.config.action_mailer.smtp_settings[:port] || 587,
          domain: ENV['SMTP_DOMAIN'] || Rails.application.config.action_mailer.smtp_settings[:domain],
          user_name: ENV['SMTP_USERNAME'] || Rails.application.config.action_mailer.smtp_settings[:user_name],
          password: ENV['SMTP_PASSWORD'] || Rails.application.config.action_mailer.smtp_settings[:password],
          authentication: ENV['SMTP_AUTHENTICATION'] || 'plain',
          enable_starttls_auto: true
        }
      end
      
      def send_message(to:, from:, subject:, body:, cc: nil, bcc: nil, reply_to: nil, metadata: {}, **options)
        require_config(:address, :port, :user_name, :password)
        
        log_info("Sending email to #{to} via SMTP")
        
        begin
          # Use ActionMailer to send
          message_id = send_via_action_mailer(
            to: to,
            from: from,
            subject: subject,
            body: body,
            cc: cc,
            bcc: bcc,
            reply_to: reply_to,
            options: options
          )
          
          log_info("Email sent successfully to #{to}, message_id: #{message_id}")
          
          success_result(
            external_id: message_id,
            details: {
              smtp_server: config[:address],
              port: config[:port]
            }
          )
        rescue => e
          log_error("Failed to send email to #{to}: #{e.message}")
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
