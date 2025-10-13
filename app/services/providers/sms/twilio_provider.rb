# Twilio SMS provider - wraps existing Twilio integration
# Provides unified interface for SMS communications

module Providers
  module Sms
    class TwilioProvider < BaseProvider
      def initialize
        @config = {
          account_sid: ENV['TWILIO_ACCOUNT_SID'],
          auth_token: ENV['TWILIO_AUTH_TOKEN'],
          phone_number: ENV['TWILIO_PHONE_NUMBER'],
          messaging_service_sid: ENV['TWILIO_MESSAGING_SERVICE_SID']
        }
        
        @client = initialize_client if configured?
      end
      
      def send_message(to:, from:, body:, metadata: {}, **options)
        require_config(:account_sid, :auth_token)
        
        # Use messaging service if available, otherwise use phone number
        unless config[:messaging_service_sid].present? || config[:phone_number].present?
          raise ConfigurationError, "Either TWILIO_MESSAGING_SERVICE_SID or TWILIO_PHONE_NUMBER required"
        end
        
        log_info("Sending SMS to #{to} via Twilio")
        
        begin
          # Format phone number
          to_number = format_phone_number(to)
          from_number = format_phone_number(from || config[:phone_number])
          
          # Build message params
          message_params = {
            body: body,
            to: to_number
          }
          
          # Use messaging service or from number
          if config[:messaging_service_sid].present?
            message_params[:messaging_service_sid] = config[:messaging_service_sid]
          else
            message_params[:from] = from_number
          end
          
          # Add status callback if configured
          if options[:status_callback_url]
            message_params[:status_callback] = options[:status_callback_url]
          end
          
          # Send via Twilio
          message = @client.messages.create(message_params)
          
          log_info("SMS sent successfully to #{to} via Twilio, SID: #{message.sid}")
          
          success_result(
            external_id: message.sid,
            details: {
              status: message.status,
              price: message.price,
              price_unit: message.price_unit
            }
          )
        rescue Twilio::REST::RestError => e
          log_error("Twilio error sending to #{to}: #{e.message}")
          raise SendError, "Twilio send failed: #{e.message}"
        rescue => e
          log_error("Failed to send SMS to #{to} via Twilio: #{e.message}")
          raise SendError, "Twilio send failed: #{e.message}"
        end
      end
      
      def verify_configuration
        require_config(:account_sid, :auth_token)
        
        begin
          # Test Twilio connection by fetching account
          @client.api.accounts(config[:account_sid]).fetch
          log_info("Twilio configuration verified successfully")
          true
        rescue => e
          log_error("Twilio configuration verification failed: #{e.message}")
          false
        end
      end
      
      def get_delivery_status(external_id)
        require_config(:account_sid, :auth_token)
        
        begin
          message = @client.messages(external_id).fetch
          
          {
            status: message.status,
            error_code: message.error_code,
            error_message: message.error_message,
            date_sent: message.date_sent,
            date_updated: message.date_updated
          }
        rescue => e
          log_error("Failed to get delivery status for #{external_id}: #{e.message}")
          nil
        end
      end
      
      def handle_webhook(payload)
        # Handle Twilio status callback
        # Status values: queued, sending, sent, failed, delivered, undelivered
        
        message_sid = payload['MessageSid']
        message_status = payload['MessageStatus']
        error_code = payload['ErrorCode']
        
        communication = Communication.find_by(external_id: message_sid)
        
        return unless communication
        
        case message_status
        when 'sent'
          CommunicationEvent.track_send(communication)
        when 'delivered'
          CommunicationEvent.track_delivery(communication)
        when 'failed', 'undelivered'
          CommunicationEvent.track_failure(
            communication,
            error: "Twilio error #{error_code}",
            details: payload.slice('ErrorCode', 'ErrorMessage')
          )
        end
        
        log_info("Webhook processed for message #{message_sid}: #{message_status}")
      end
      
      private
      
      def configured?
        config[:account_sid].present? && config[:auth_token].present?
      end
      
      def initialize_client
        require 'twilio-ruby'
        
        Twilio::REST::Client.new(
          config[:account_sid],
          config[:auth_token]
        )
      rescue LoadError
        log_error("twilio-ruby gem not found. Add to Gemfile: gem 'twilio-ruby'")
        nil
      end
      
      def format_phone_number(number)
        # Remove all non-numeric characters
        cleaned = number.to_s.gsub(/[^0-9+]/, '')
        
        # Add + prefix if not present
        cleaned.start_with?('+') ? cleaned : "+#{cleaned}"
      end
    end
  end
end
