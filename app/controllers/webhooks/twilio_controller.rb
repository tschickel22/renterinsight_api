# frozen_string_literal: true

module Webhooks
  class TwilioController < ActionController::API
    before_action :verify_twilio_signature, only: [:sms_status]

    # POST /webhooks/twilio/sms/status
    def sms_status
      message_sid = params['MessageSid']
      status = params['MessageStatus']
      
      Rails.logger.info "[Twilio] Webhook received: SID=#{message_sid}, Status=#{status}"
      
      communication = Communication.find_by(external_id: message_sid)
      
      unless communication
        Rails.logger.warn "[Twilio] Communication not found for SID: #{message_sid}"
        return head :ok
      end
      
      case status
      when 'sent'
        unless communication.sent_at
          communication.update!(sent_at: Time.current)
          CommunicationEvent.track_send(communication, details: twilio_params)
        end
        
      when 'delivered'
        communication.update!(
          status: 'delivered',
          delivered_at: Time.current
        )
        CommunicationEvent.track_delivery(communication, details: twilio_params)
        Rails.logger.info "[Twilio] SMS #{communication.id} delivered to #{communication.to_address}"
        
      when 'undelivered', 'failed'
        error_code = params['ErrorCode']
        error_message = params['ErrorMessage'] || 'Unknown error'
        
        communication.mark_as_failed!("Twilio Error #{error_code}: #{error_message}")
        CommunicationEvent.track_failure(
          communication,
          error: error_message,
          details: twilio_params
        )
        Rails.logger.error "[Twilio] SMS #{communication.id} failed: #{error_message}"
      end
      
      head :ok
    rescue => e
      Rails.logger.error "[Twilio] Webhook error: #{e.message}"
      Rails.logger.error e.backtrace.first(5).join("\n")
      head :ok
    end
    
    private
    
    def verify_twilio_signature
      auth_token = ENV['TWILIO_AUTH_TOKEN']
      
      unless auth_token.present?
        Rails.logger.warn "[Twilio] Auth token not configured - skipping signature verification"
        return true
      end
      
      signature = request.headers['X-Twilio-Signature']
      
      unless signature.present?
        Rails.logger.error "[Twilio] Missing X-Twilio-Signature header"
        head :forbidden
        return false
      end
      
      validator = Twilio::Security::RequestValidator.new(auth_token)
      url = request.original_url
      post_params = request.request_parameters
      
      unless validator.validate(url, post_params, signature)
        Rails.logger.error "[Twilio] Invalid signature - possible spoofed request"
        head :forbidden
        return false
      end
      
      true
    rescue NameError => e
      Rails.logger.warn "[Twilio] Twilio gem not loaded - skipping signature verification: #{e.message}"
      true
    rescue => e
      Rails.logger.error "[Twilio] Signature verification error: #{e.message}"
      head :internal_server_error
      false
    end
    
    def twilio_params
      {
        message_sid: params['MessageSid'],
        from: params['From'],
        to: params['To'],
        status: params['MessageStatus'],
        error_code: params['ErrorCode'],
        error_message: params['ErrorMessage'],
        price: params['Price'],
        price_unit: params['PriceUnit']
      }.compact
    end
  end
end
