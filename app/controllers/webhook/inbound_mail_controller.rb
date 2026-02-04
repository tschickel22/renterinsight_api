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
    
    # Parse the email using ParserService
    parser = InboundEmail::ParserService.new(email_data)
    parsed_email = parser.parse
    
    Rails.logger.info "[InboundMail] Token: #{parsed_email[:token]&.inspect}"
    Rails.logger.info "[InboundMail] Body text: #{parsed_email[:body_text]&.[](0..200)}"
    
    # Process the email (match token, create Communication)
    processor = InboundEmail::ProcessorService.new(parsed_email)
    result = processor.process
    
    if result[:success]
      Rails.logger.info "[InboundMail] ✅ SUCCESS: Communication ##{result[:communication_id]} created"
    else
      Rails.logger.warn "[InboundMail] ⚠️ FAILED: #{result[:error]}"
    end
    
    Rails.logger.info "[InboundMail] ========================================="
    
    render json: { success: true, message: 'Email processed', result: result }
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
