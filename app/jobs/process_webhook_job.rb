# frozen_string_literal: true

class ProcessWebhookJob < ApplicationJob
  queue_as :webhooks
  
  # Don't retry webhook processing - webhooks should be idempotent
  # and providers will typically retry on failure
  
  def perform(provider, webhook_data)
    Rails.logger.info("Processing webhook from #{provider}")
    
    case provider.to_s.downcase
    when 'twilio'
      process_twilio_webhook(webhook_data)
    when 'aws_ses', 'ses'
      process_ses_webhook(webhook_data)
    when 'gmail', 'gmail_relay'
      process_gmail_webhook(webhook_data)
    when 'smtp'
      process_smtp_webhook(webhook_data)
    else
      Rails.logger.warn("Unknown webhook provider: #{provider}")
    end
  rescue => e
    Rails.logger.error("Error processing webhook from #{provider}: #{e.message}")
    Rails.logger.error(e.backtrace.join("\n"))
  end
  
  private
  
  # Process Twilio webhook for SMS events
  def process_twilio_webhook(data)
    message_sid = data['MessageSid']
    status = data['MessageStatus']
    
    return unless message_sid && status
    
    # Find communication by external_id (MessageSid)
    communication = Communication.find_by(external_id: message_sid)
    
    unless communication
      Rails.logger.warn("Communication not found for Twilio MessageSid: #{message_sid}")
      return
    end
    
    # Map Twilio status to our status
    case status.downcase
    when 'sent', 'delivered'
      communication.track_event('delivered', provider_data: data)
    when 'failed', 'undelivered'
      communication.track_event('failed', provider_data: data.merge('error' => data['ErrorMessage'] || 'Delivery failed'))
    end
    
    Rails.logger.info("Processed Twilio webhook for communication #{communication.id}: #{status}")
  end
  
  # Process AWS SES webhook for email events
  def process_ses_webhook(data)
    # SES sends SNS notifications, structure varies by event type
    message_type = data['Type']
    
    case message_type
    when 'SubscriptionConfirmation'
      # Auto-confirm SNS subscription (you'd typically hit the SubscribeURL)
      Rails.logger.info("SES SNS Subscription confirmation received")
      return
    when 'Notification'
      process_ses_notification(JSON.parse(data['Message']))
    end
  end
  
  def process_ses_notification(message)
    notification_type = message['notificationType']
    message_id = message.dig('mail', 'messageId')
    
    return unless message_id
    
    communication = Communication.find_by(external_id: message_id)
    
    unless communication
      Rails.logger.warn("Communication not found for SES MessageId: #{message_id}")
      return
    end
    
    case notification_type
    when 'Bounce'
      communication.track_event('bounced', provider_data: message)
    when 'Complaint'
      communication.track_event('complaint', provider_data: message)
    when 'Delivery'
      communication.track_event('delivered', provider_data: message)
    end
    
    Rails.logger.info("Processed SES webhook for communication #{communication.id}: #{notification_type}")
  end
  
  # Process Gmail webhook (Gmail API push notifications)
  def process_gmail_webhook(data)
    # Gmail uses Pub/Sub for notifications
    # This would require decoding the message and checking history
    Rails.logger.info("Gmail webhook processing not fully implemented")
    # TODO: Implement Gmail webhook processing if needed
  end
  
  # Process SMTP webhook (if using a service like SendGrid)
  def process_smtp_webhook(data)
    event_type = data['event']
    message_id = data['message_id']
    
    return unless message_id
    
    communication = Communication.find_by(external_id: message_id)
    
    unless communication
      Rails.logger.warn("Communication not found for SMTP MessageId: #{message_id}")
      return
    end
    
    case event_type
    when 'delivered'
      communication.track_event('delivered', provider_data: data)
    when 'bounce', 'dropped'
      communication.track_event('bounced', provider_data: data)
    when 'open'
      communication.track_event('opened', provider_data: data)
    when 'click'
      communication.track_event('clicked', provider_data: data)
    when 'spam_report'
      communication.track_event('spam_report', provider_data: data)
    end
    
    Rails.logger.info("Processed SMTP webhook for communication #{communication.id}: #{event_type}")
  end
end
