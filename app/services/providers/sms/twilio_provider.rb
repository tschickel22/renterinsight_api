# frozen_string_literal: true

module Providers
  module Sms
    class TwilioProvider
      attr_reader :company, :location, :config
      
      def initialize(company: nil, location: nil)
        @company = company
        @location = location
        @config = load_config
      end
      
      def send_message(to:, from: nil, body:, **options)
        validate_config!
        
        # Use from parameter or fall back to config
        from_number = from || config[:from_number]
        
        Rails.logger.info "📱 Sending SMS via Twilio to #{to} from #{from_number}"
        
        # Send SMS via direct HTTP (same as Platform test SMS)
        result = send_via_http(
          to: to,
          from: from_number,
          body: body,
          account_sid: config[:twilio_account_sid],
          auth_token: config[:twilio_auth_token]
        )
        
        if result[:success]
          Rails.logger.info "✅ SMS sent successfully via Twilio: #{result[:message_sid]}"
          {
            success: true,
            external_id: result[:message_sid],
            provider: 'twilio'
          }
        else
          Rails.logger.error "❌ Twilio delivery failed: #{result[:error]}"
          raise DeliveryError, "Twilio delivery failed: #{result[:error]}"
        end
      rescue DeliveryError
        raise
      rescue StandardError => e
        Rails.logger.error "❌ SMS delivery failed: #{e.message}"
        Rails.logger.error e.backtrace.first(5).join("\n")
        raise DeliveryError, "SMS delivery failed: #{e.message}"
      end
      
      private
      
      def send_via_http(to:, from:, body:, account_sid:, auth_token:)
        require 'net/http'
        require 'uri'
        require 'json'
        
        uri = URI.parse("https://api.twilio.com/2010-04-01/Accounts/#{account_sid}/Messages.json")
        
        request = Net::HTTP::Post.new(uri)
        request.basic_auth(account_sid, auth_token)
        
        request.set_form_data({
          'From' => from,
          'To' => to,
          'Body' => body
        })
        
        response = Net::HTTP.start(uri.hostname, uri.port, use_ssl: true) do |http|
          http.request(request)
        end
        
        result = JSON.parse(response.body)
        
        if response.code.to_i == 201
          { 
            success: true, 
            message_sid: result['sid'],
            status: result['status']
          }
        else
          { 
            success: false, 
            error: result['message'] || 'Twilio API error'
          }
        end
      rescue => e
        { success: false, error: e.message }
      end
      
      def load_config
        settings_service = company ? 
          CommunicationSettingsService.for_company(company, location: location) : 
          CommunicationSettingsService.platform
        
        settings_service.sms_config
      end
      
      def validate_config!
        raise ConfigurationError, "Twilio Account SID is required" if config[:twilio_account_sid].blank?
        raise ConfigurationError, "Twilio Auth Token is required" if config[:twilio_auth_token].blank?
        raise ConfigurationError, "From number is required" if config[:from_number].blank?
      end
      
      class ConfigurationError < StandardError; end
      class DeliveryError < StandardError; end
    end
  end
end
