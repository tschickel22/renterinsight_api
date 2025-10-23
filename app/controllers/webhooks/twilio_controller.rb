# frozen_string_literal: true

module Webhooks
  class TwilioController < ApplicationController
    # Skip authentication for webhook endpoints (Twilio calls these, not authenticated users)
    skip_before_action :authenticate, if: :skip_auth?
    
    # POST /webhooks/twilio/sms/status
    def sms_status
      message_sid = params['MessageSid']
      status = params['MessageStatus']
      
      Rails.logger.info "[Twilio] Webhook received: SID=#{message_sid}, Status=#{status}"
      
      # Find communication by external_id (Twilio message SID)
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
      head :ok  # Always return 200 to Twilio
    end
    
    private
    
    def skip_auth?
      action_name == 'sms_status'
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
