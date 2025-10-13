# Gmail Relay provider for sending emails through Gmail's SMTP relay
# Requires Google Workspace with SMTP relay configured
# Documentation: https://support.google.com/a/answer/176600

module Providers
  module Email
    class GmailRelayProvider < BaseProvider
      GMAIL_RELAY_HOST = 'smtp-relay.gmail.com'
      GMAIL_RELAY_PORT = 587
      
      def initialize
        @config = {
          address: GMAIL_RELAY_HOST,
          port: GMAIL_RELAY_PORT,
          domain: ENV['GMAIL_RELAY_DOMAIN'],
          user_name: ENV['GMAIL_RELAY_USERNAME'],
          password: ENV['GMAIL_RELAY_PASSWORD'],
          authentication: 'plain',
          enable_starttls_auto: true
        }
      end
      
      def send_message(to:, from:, subject:, body:, cc: nil, bcc: nil, reply_to: nil, metadata: {}, **options)
        require_config(:domain, :user_name, :password)
        
        log_info("Sending email to #{to} via Gmail Relay")
        
        begin
          message_id = send_via_gmail_relay(
            to: to,
            from: from,
            subject: subject,
            body: body,
            cc: cc,
            bcc: bcc,
            reply_to: reply_to,
            options: options
          )
          
          log_info("Email sent successfully to #{to} via Gmail Relay, message_id: #{message_id}")
          
          success_result(
            external_id: message_id,
            details: {
              relay_host: GMAIL_RELAY_HOST,
              port: GMAIL_RELAY_PORT
            }
          )
        rescue => e
          log_error("Failed to send email to #{to} via Gmail Relay: #{e.message}")
          raise SendError, "Gmail Relay send failed: #{e.message}"
        end
      end
      
      def verify_configuration
        require_config(:domain, :user_name, :password)
        
        begin
          Net::SMTP.start(
            GMAIL_RELAY_HOST,
            GMAIL_RELAY_PORT,
            config[:domain],
            config[:user_name],
            config[:password],
            'plain'
          ) do |smtp|
            log_info("Gmail Relay configuration verified successfully")
          end
          true
        rescue => e
          log_error("Gmail Relay configuration verification failed: #{e.message}")
          false
        end
      end
      
      private
      
      def send_via_gmail_relay(to:, from:, subject:, body:, cc:, bcc:, reply_to:, options:)
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
        
        # Add Gmail-specific headers
        mail.header['X-Google-Original-From'] = from
        
        # Add custom headers if provided
        if options[:headers]
          options[:headers].each do |key, value|
            mail.header[key] = value
          end
        end
        
        # Configure Gmail Relay delivery
        mail.delivery_method :smtp, config
        
        # Send and return message ID
        mail.deliver!
        mail.message_id
      end
    end
  end
end
