# frozen_string_literal: true

class Webhook::InboundMailController < ActionController::Base
  skip_before_action :verify_authenticity_token  # CRITICAL - skip CSRF for webhooks
  
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
    mail_obj = email_data['mail']
    
    Rails.logger.info "[InboundMail] ========================================="
    Rails.logger.info "[InboundMail] Message ID: #{mail_obj['messageId']}"
    Rails.logger.info "[InboundMail] From: #{mail_obj['source']}"
    Rails.logger.info "[InboundMail] To: #{mail_obj['destination']&.join(', ')}"
    Rails.logger.info "[InboundMail] Subject: #{mail_obj['commonHeaders']&.dig('subject')}"
    Rails.logger.info "[InboundMail] Timestamp: #{mail_obj['timestamp']}"
    
    # Get the content (if available in notification)
    content = email_data['content']
    if content
      Rails.logger.info "[InboundMail] Content length: #{content.length} bytes"
      Rails.logger.info "[InboundMail] Content preview: #{content[0..200]}"
    else
      Rails.logger.info "[InboundMail] No content in notification (may need S3 fetch)"
    end
    
    # Log the full raw data for debugging
    Rails.logger.info "[InboundMail] Full mail object: #{mail_obj.to_json}"
    Rails.logger.info "[InboundMail] ========================================="
    
    render json: { success: true, message: 'Email logged' }
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
