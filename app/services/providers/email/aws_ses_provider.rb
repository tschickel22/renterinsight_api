# AWS SES (Simple Email Service) provider
# Provides high deliverability, detailed tracking, and webhook support
# Requires aws-sdk-ses gem

module Providers
  module Email
    class AwsSesProvider < BaseProvider
      def initialize
        @config = {
          region: ENV['AWS_SES_REGION'] || 'us-east-1',
          access_key_id: ENV['AWS_ACCESS_KEY_ID'],
          secret_access_key: ENV['AWS_SECRET_ACCESS_KEY'],
          configuration_set: ENV['AWS_SES_CONFIGURATION_SET']
        }
        
        @client = initialize_client if configured?
      end
      
      def send_message(to:, from:, subject:, body:, cc: nil, bcc: nil, reply_to: nil, metadata: {}, **options)
        require_config(:access_key_id, :secret_access_key, :region)
        
        log_info("Sending email to #{to} via AWS SES")
        
        begin
          # Build destination
          destination = { to_addresses: [to].flatten }
          destination[:cc_addresses] = [cc].flatten if cc.present?
          destination[:bcc_addresses] = [bcc].flatten if bcc.present?
          
          # Build message
          message = {
            subject: { data: subject, charset: 'UTF-8' },
            body: build_body(body)
          }
          
          # Send via SES
          response = @client.send_email(
            source: from,
            destination: destination,
            message: message,
            reply_to_addresses: reply_to ? [reply_to].flatten : nil,
            configuration_set_name: config[:configuration_set],
            tags: build_tags(metadata)
          )
          
          message_id = response.message_id
          
          log_info("Email sent successfully to #{to} via AWS SES, message_id: #{message_id}")
          
          success_result(
            external_id: message_id,
            details: {
              region: config[:region],
              configuration_set: config[:configuration_set]
            }
          )
        rescue Aws::SES::Errors::ServiceError => e
          log_error("AWS SES error sending to #{to}: #{e.message}")
          raise SendError, "AWS SES send failed: #{e.message}"
        rescue => e
          log_error("Failed to send email to #{to} via AWS SES: #{e.message}")
          raise SendError, "AWS SES send failed: #{e.message}"
        end
      end
      
      def verify_configuration
        require_config(:access_key_id, :secret_access_key, :region)
        
        begin
          # Test SES connection by getting send quota
          @client.get_send_quota
          log_info("AWS SES configuration verified successfully")
          true
        rescue => e
          log_error("AWS SES configuration verification failed: #{e.message}")
          false
        end
      end
      
      def get_delivery_status(external_id)
        # Note: SES doesn't provide direct message status lookup
        # Status is typically tracked via SNS notifications/webhooks
        raise NotImplementedError, "Use webhooks for SES delivery status"
      end
      
      def handle_webhook(payload)
        # Handle SNS notification from SES
        # Payload types: Bounce, Complaint, Delivery, Send, Reject, Open, Click
        
        message_type = payload.dig('Type')
        message = JSON.parse(payload.dig('Message') || '{}')
        
        case message_type
        when 'Notification'
          notification_type = message.dig('notificationType')
          
          case notification_type
          when 'Bounce'
            handle_bounce(message)
          when 'Complaint'
            handle_complaint(message)
          when 'Delivery'
            handle_delivery(message)
          else
            log_info("Unhandled SES notification type: #{notification_type}")
          end
        end
      end
      
      private
      
      def configured?
        config[:access_key_id].present? && 
        config[:secret_access_key].present? && 
        config[:region].present?
      end
      
      def initialize_client
        require 'aws-sdk-ses'
        
        Aws::SES::Client.new(
          region: config[:region],
          access_key_id: config[:access_key_id],
          secret_access_key: config[:secret_access_key]
        )
      rescue LoadError
        log_error("aws-sdk-ses gem not found. Add to Gemfile: gem 'aws-sdk-ses'")
        nil
      end
      
      def build_body(body)
        if body.include?('</html>') || body.include?('<html>')
          { html: { data: body, charset: 'UTF-8' } }
        else
          { text: { data: body, charset: 'UTF-8' } }
        end
      end
      
      def build_tags(metadata)
        return nil unless metadata.present?
        
        metadata.slice(:category, :quote_id, :account_id, :lead_id).map do |key, value|
          { name: key.to_s, value: value.to_s }
        end
      end
      
      def handle_bounce(message)
        bounce = message.dig('bounce')
        bounce_type = bounce.dig('bounceType') # Permanent or Transient
        
        bounced_recipients = bounce.dig('bouncedRecipients') || []
        
        bounced_recipients.each do |recipient|
          email = recipient.dig('emailAddress')
          
          log_info("Bounce received for #{email}: #{bounce_type}")
          
          # Find communication by external ID
          message_id = message.dig('mail', 'messageId')
          communication = Communication.find_by(external_id: message_id)
          
          if communication
            CommunicationEvent.track_bounce(
              communication,
              reason: recipient.dig('diagnosticCode'),
              details: { bounce_type: bounce_type }
            )
            
            # Handle hard bounces
            if bounce_type == 'Permanent'
              CommunicationPreferenceService.handle_bounce(
                communication: communication,
                bounce_type: 'hard',
                reason: recipient.dig('diagnosticCode')
              )
            end
          end
        end
      end
      
      def handle_complaint(message)
        complaint = message.dig('complaint')
        complained_recipients = complaint.dig('complainedRecipients') || []
        
        complained_recipients.each do |recipient|
          email = recipient.dig('emailAddress')
          
          log_info("Spam complaint received for #{email}")
          
          # Find communication and handle complaint
          message_id = message.dig('mail', 'messageId')
          communication = Communication.find_by(external_id: message_id)
          
          if communication
            CommunicationEvent.track(
              communication: communication,
              event_type: 'spam_report'
            )
            
            CommunicationPreferenceService.handle_spam_complaint(
              communication: communication
            )
          end
        end
      end
      
      def handle_delivery(message)
        message_id = message.dig('mail', 'messageId')
        communication = Communication.find_by(external_id: message_id)
        
        if communication
          CommunicationEvent.track_delivery(communication)
          log_info("Delivery confirmed for message #{message_id}")
        end
      end
    end
  end
end
