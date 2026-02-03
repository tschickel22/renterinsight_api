# frozen_string_literal: true

class Webhook::InboundMailController < ActionController::Base
  
  # POST /webhook/inbound_mail/handle
  def handle
    # Parse SNS notification from AWS SES
    message = JSON.parse(request.body.read)
    
    # Handle SNS subscription confirmation (first time setup)
    if message['Type'] == 'SubscriptionConfirmation'
      confirm_sns_subscription(message)
      return render json: { success: true, message: 'SNS subscription confirmed' }
    end
    
    # Parse email notification from SNS message
    email_data = JSON.parse(message['Message'])
    
    Rails.logger.info "[InboundMail] Received email: #{email_data.dig('mail', 'messageId')}"
    
    render json: { success: true, message: 'Email processed' }
  rescue JSON::ParserError => e
    Rails.logger.error "[InboundMail] JSON parse error: #{e.message}"
    render json: { error: 'Invalid JSON' }, status: :bad_request
  rescue => e
    Rails.logger.error "[InboundMail] Error: #{e.message}"
    render json: { error: e.message }, status: :internal_server_error
  end
  
  private
  
  def confirm_sns_subscription(message)
    subscribe_url = message['SubscribeURL']
    
    unless subscribe_url
      Rails.logger.error "[InboundMail] No SubscribeURL"
      return
    end
    
    Rails.logger.info "[InboundMail] Confirming SNS: #{subscribe_url}"
    
    require 'net/http'
    uri = URI(subscribe_url)
    response = Net::HTTP.get_response(uri)
    
    if response.is_a?(Net::HTTPSuccess)
      Rails.logger.info "[InboundMail] ✅ SNS confirmed"
    else
      Rails.logger.error "[InboundMail] ❌ SNS failed: #{response.code}"
    end
  rescue => e
    Rails.logger.error "[InboundMail] SNS error: #{e.message}"
  end
end
