# frozen_string_literal: true

# Handles inbound emails from AWS SES via SNS webhook
# Supports two types of inbound emails:
# 1. BCC Capture: User sends from Gmail/Outlook, BCCs crm+{user_id}@mail.renterinsight.com
# 2. Reply Tracking: Lead/client replies to platform-sent email at reply+{communication_id}@mail.renterinsight.com
#
# AWS SES Setup Required:
# - MX record: mail.renterinsight.com → inbound-smtp.us-east-1.amazonaws.com
# - Receipt rule: reply+*@mail.renterinsight.com, crm+*@mail.renterinsight.com → SNS Topic
# - SNS subscription: HTTPS webhook to /webhooks/inbound_mail/process
#
class Webhooks::InboundMailController < ApplicationController
  skip_before_action :verify_authenticity_token
  skip_before_action :authenticate
  skip_before_action :set_company_scope
  
  # POST /webhooks/inbound_mail/process
  def process
    # Parse SNS notification from AWS SES
    message = JSON.parse(request.body.read)
    
    # Handle SNS subscription confirmation (first time setup)
    if message['Type'] == 'SubscriptionConfirmation'
      confirm_sns_subscription(message)
      return render json: { success: true, message: 'SNS subscription confirmed' }
    end
    
    # Parse email notification from SNS message
    email_data = JSON.parse(message['Message'])
    
    Rails.logger.info "[InboundMail] Received email notification: #{email_data.dig('mail', 'messageId')}"
    
    # Extract recipient addresses
    to_addresses = email_data.dig('mail', 'commonHeaders', 'to') || []
    
    # Find platform reply address (reply+* or crm+*)
    platform_address = to_addresses.find { |addr| ReplyToAddressService.platform_reply_address?(addr) }
    
    unless platform_address
      Rails.logger.warn "[InboundMail] No platform address found in recipients: #{to_addresses.inspect}"
      return render json: { error: 'No platform address found' }, status: :unprocessable_entity
    end
    
    # Parse address to determine type and routing
    parsed = ReplyToAddressService.parse(platform_address)
    
    unless parsed
      Rails.logger.error "[InboundMail] Failed to parse address: #{platform_address}"
      return render json: { error: 'Invalid address format' }, status: :unprocessable_entity
    end
    
    Rails.logger.info "[InboundMail] Parsed address - Type: #{parsed[:type]}, Data: #{parsed.except(:type).inspect}"
    
    # Route to appropriate handler
    case parsed[:type]
    when :bcc_capture
      handle_bcc_capture(email_data, parsed[:user_id])
    when :reply
      handle_reply(email_data, parsed[:communication_id])
    else
      Rails.logger.error "[InboundMail] Unknown address type: #{parsed[:type]}"
      return render json: { error: 'Unknown address type' }, status: :unprocessable_entity
    end
    
    render json: { success: true }
  rescue JSON::ParserError => e
    Rails.logger.error "[InboundMail] JSON parse error: #{e.message}"
    render json: { error: 'Invalid JSON' }, status: :bad_request
  rescue => e
    Rails.logger.error "[InboundMail] Error processing email: #{e.message}"
    Rails.logger.error e.backtrace.first(10).join("\n")
    render json: { error: e.message }, status: :internal_server_error
  end
  
  private
  
  # Handle BCC capture (user sent email from external client, BCCed platform)
  def handle_bcc_capture(email_data, user_id)
    user = User.find_by(id: user_id)
    unless user
      Rails.logger.error "[InboundMail] User not found: #{user_id}"
      return
    end
    
    Rails.logger.info "[InboundMail] Processing BCC capture for user #{user_id} (#{user.email})"
    
    # Extract email metadata
    from = extract_first_email(email_data.dig('mail', 'commonHeaders', 'from'))
    to = extract_first_email(email_data.dig('mail', 'commonHeaders', 'to'), exclude_pattern: /crm\+/)
    subject = email_data.dig('mail', 'commonHeaders', 'subject')
    timestamp = parse_timestamp(email_data.dig('mail', 'timestamp'))
    message_id = email_data.dig('mail', 'messageId')
    
    Rails.logger.info "[InboundMail] BCC Email - From: #{from}, To: #{to}, Subject: #{subject}"
    
    # Get email body
    body = extract_email_body(email_data)
    
    # Try to find matching entity (Lead/Contact/Account) by recipient email
    entity = find_entity_by_email(to, user.company_id)
    
    if entity
      Rails.logger.info "[InboundMail] Found matching entity: #{entity.class.name} ##{entity.id}"
    else
      Rails.logger.info "[InboundMail] No matching entity found, attaching to user"
    end
    
    # Create Communication record
    comm = Communication.create!(
      communicable: entity || user,  # Attach to Lead/Contact/Account if found, else User
      direction: 'outbound',  # User SENT this email
      channel: 'email',
      from_address: from,
      to_address: to,
      subject: subject,
      body: body,
      sent_at: timestamp,
      status: 'sent',
      metadata: {
        source: 'bcc_capture',
        captured_at: Time.current,
        user_id: user_id,
        message_id: message_id
      }
    )
    
    Rails.logger.info "[InboundMail] ✅ BCC captured: Communication #{comm.id} for user #{user_id}"
    
    # Optional: Broadcast notification to user via ActionCable
    # ActionCable.server.broadcast "user_notifications_#{user_id}", {
    #   type: 'email_captured',
    #   communication_id: comm.id,
    #   subject: subject
    # }
  rescue => e
    Rails.logger.error "[InboundMail] BCC capture failed: #{e.message}"
    Rails.logger.error e.backtrace.first(5).join("\n")
  end
  
  # Handle reply to platform-sent email
  def handle_reply(email_data, communication_id)
    # Find original communication
    original = Communication.find_by(id: communication_id)
    unless original
      Rails.logger.error "[InboundMail] Original communication not found: #{communication_id}"
      return
    end
    
    Rails.logger.info "[InboundMail] Processing reply to communication #{communication_id} (#{original.communicable_type} ##{original.communicable_id})"
    
    # Extract reply metadata
    from = extract_first_email(email_data.dig('mail', 'commonHeaders', 'from'))
    to = extract_first_email(email_data.dig('mail', 'commonHeaders', 'to'))
    subject = email_data.dig('mail', 'commonHeaders', 'subject')
    timestamp = parse_timestamp(email_data.dig('mail', 'timestamp'))
    message_id = email_data.dig('mail', 'messageId')
    
    Rails.logger.info "[InboundMail] Reply Email - From: #{from}, To: #{to}, Subject: #{subject}"
    
    # Get email body
    body = extract_email_body(email_data)
    
    # Create reply Communication
    reply = Communication.create!(
      communicable: original.communicable,  # Same entity (Lead/Contact/etc)
      direction: 'inbound',  # They replied TO us
      channel: 'email',
      from_address: from,
      to_address: to,
      subject: subject,
      body: body,
      sent_at: timestamp,
      delivered_at: Time.current,
      status: 'delivered',
      metadata: {
        source: 'email_reply',
        in_reply_to_communication_id: communication_id,
        message_id: message_id,
        thread_id: original.metadata&.dig('thread_id') || communication_id
      }
    )
    
    Rails.logger.info "[InboundMail] ✅ Reply captured: Communication #{reply.id} in reply to #{communication_id}"
    
    # Optional: Notify entity owner about reply
    if original.communicable.respond_to?(:owner) && original.communicable.owner
      owner_id = original.communicable.owner.id
      Rails.logger.info "[InboundMail] Notifying owner #{owner_id} about reply"
      
      # Broadcast via ActionCable
      # ActionCable.server.broadcast "user_notifications_#{owner_id}", {
      #   type: 'entity_replied',
      #   entity_type: original.communicable_type,
      #   entity_id: original.communicable_id,
      #   entity_name: original.communicable.try(:name) || original.communicable.try(:full_name),
      #   communication_id: reply.id,
      #   subject: subject
      # }
    end
  rescue => e
    Rails.logger.error "[InboundMail] Reply capture failed: #{e.message}"
    Rails.logger.error e.backtrace.first(5).join("\n")
  end
  
  # Extract email body from SES message
  # SES can send content inline (for small emails) or store in S3 (for large emails)
  def extract_email_body(email_data)
    # Try to get content from inline data
    content = email_data.dig('content')
    
    if content.present?
      return parse_email_content(content)
    end
    
    # If stored in S3, we'd need to fetch it
    # For now, return a placeholder - S3 storage can be added later
    Rails.logger.warn "[InboundMail] Email content not in notification - may be in S3"
    "Email body not available. Configure S3 storage for full email content."
  end
  
  # Parse raw MIME email content
  def parse_email_content(raw_content)
    # Parse MIME email using Ruby Mail gem (handles multipart, HTML, plain text)
    mail = Mail.read_from_string(raw_content)
    
    # Prefer plain text body
    if mail.text_part
      body = mail.text_part.decoded
    elsif mail.html_part
      # Strip HTML tags for plain text storage
      html = mail.html_part.decoded
      body = ActionView::Base.full_sanitizer.sanitize(html)
    elsif mail.body
      body = mail.body.decoded
    else
      body = "Unable to parse email body"
    end
    
    # Trim excessive whitespace
    body.strip
  rescue => e
    Rails.logger.error "[InboundMail] Failed to parse email content: #{e.message}"
    # Return first 1000 chars of raw content as fallback
    raw_content[0..1000]
  end
  
  # Extract first email address from array or string
  # Handles formats like: "John Doe <john@example.com>" or ["john@example.com"]
  def extract_first_email(data, exclude_pattern: nil)
    return nil if data.blank?
    
    # Convert to array if string
    emails = data.is_a?(Array) ? data : [data]
    
    # Filter out excluded patterns (like BCC addresses)
    if exclude_pattern
      emails = emails.reject { |e| e.to_s.match?(exclude_pattern) }
    end
    
    # Get first email
    first = emails.first
    return nil unless first
    
    # Handle "Name <email@example.com>" format
    if first.include?('<') && first.include?('>')
      match = first.match(/<([^>]+)>/)
      match ? match[1] : first
    else
      first
    end
  end
  
  # Parse ISO timestamp from SES
  def parse_timestamp(timestamp_str)
    return Time.current if timestamp_str.blank?
    
    Time.parse(timestamp_str)
  rescue
    Time.current
  end
  
  # Find Lead, Contact, or Account by email address
  def find_entity_by_email(email, company_id)
    return nil if email.blank? || company_id.blank?
    
    # Normalize email
    email_normalized = email.downcase.strip
    
    # Try Lead first (most common for outbound sales)
    lead = Lead.where(company_id: company_id)
               .where('LOWER(email) = ?', email_normalized)
               .first
    return lead if lead
    
    # Try Contact
    contact = Contact.where(company_id: company_id)
                     .where('LOWER(email) = ?', email_normalized)
                     .first
    return contact if contact
    
    # Try Account by primary email
    account = Account.where(company_id: company_id)
                     .where('LOWER(email) = ?', email_normalized)
                     .first
    return account if account
    
    # Not found
    nil
  end
  
  # Auto-confirm SNS subscription (first time setup)
  def confirm_sns_subscription(message)
    subscribe_url = message['SubscribeURL']
    
    unless subscribe_url
      Rails.logger.error "[InboundMail] No SubscribeURL in confirmation message"
      return
    end
    
    Rails.logger.info "[InboundMail] Confirming SNS subscription: #{subscribe_url}"
    
    require 'net/http'
    uri = URI(subscribe_url)
    response = Net::HTTP.get_response(uri)
    
    if response.is_a?(Net::HTTPSuccess)
      Rails.logger.info "[InboundMail] ✅ SNS subscription confirmed successfully"
    else
      Rails.logger.error "[InboundMail] ❌ Failed to confirm SNS subscription: #{response.code} #{response.message}"
    end
  rescue => e
    Rails.logger.error "[InboundMail] Error confirming SNS subscription: #{e.message}"
  end
end
