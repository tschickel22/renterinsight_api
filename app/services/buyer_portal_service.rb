# frozen_string_literal: true

class BuyerPortalService
  # Create portal access for a buyer with optional welcome email
  def self.create_portal_access(buyer, email, send_welcome: true)
    # Generate a secure random password
    generated_password = SecureRandom.alphanumeric(16)
    
    # Create buyer portal access
    portal_access = BuyerPortalAccess.create!(
      buyer: buyer,
      email: email,
      password: generated_password,
      password_confirmation: generated_password,
      portal_enabled: true,
      email_opt_in: true,
      sms_opt_in: false,
      marketing_opt_in: false
    )
    
    send_welcome_email(portal_access) if send_welcome
    
    portal_access
  end
  
  # Send welcome email with Communication record
  def self.send_welcome_email(buyer_access)
    # Send the email
    mail = BuyerPortalMailer.welcome_email(buyer_access).deliver_now
    
    # Create Communication record
    communication = Communication.create!(
      communicable: buyer_access.buyer,
      direction: 'outbound',
      channel: 'email',
      provider: 'smtp',
      status: 'sent',
      subject: "Welcome to #{ENV.fetch('COMPANY_NAME', 'RenterInsight')} Buyer Portal",
      body: "Welcome email sent to #{buyer_access.email}",
      from_address: ENV.fetch('PORTAL_FROM_EMAIL', 'portal@renterinsight.com'),
      to_address: buyer_access.email,
      portal_visible: false,
      sent_at: Time.current,
      metadata: {
        'email_type' => 'welcome',
        'buyer_access_id' => buyer_access.id,
        'message_id' => mail.message_id
      }
    )
    
    communication.mark_as_sent!
    
    Rails.logger.info "[BuyerPortalService] Welcome email sent to: #{buyer_access.email}"
    communication
  end
  
  # Send magic link email with Communication record
  def self.send_magic_link_email(buyer_access)
    # Generate the token first
    buyer_access.generate_login_token
    
    # Send the email
    mail = BuyerPortalMailer.magic_link_email(buyer_access).deliver_now
    
    # Create Communication record
    communication = Communication.create!(
      communicable: buyer_access.buyer,
      direction: 'outbound',
      channel: 'email',
      provider: 'smtp',
      status: 'sent',
      subject: "Your Magic Link to #{ENV.fetch('COMPANY_NAME', 'RenterInsight')} Portal",
      body: "Magic link email sent to #{buyer_access.email}. Link expires in 15 minutes.",
      from_address: ENV.fetch('PORTAL_FROM_EMAIL', 'portal@renterinsight.com'),
      to_address: buyer_access.email,
      portal_visible: false,
      sent_at: Time.current,
      metadata: {
        'email_type' => 'magic_link',
        'buyer_access_id' => buyer_access.id,
        'token_expires_at' => buyer_access.login_token_expires_at,
        'message_id' => mail.message_id
      }
    )
    
    communication.mark_as_sent!
    
    Rails.logger.info "[BuyerPortalService] Magic link sent to: #{buyer_access.email}"
    Rails.logger.info "[BuyerPortalService] Token expires at: #{buyer_access.login_token_expires_at}"
    communication
  end
  
  # Send password reset email with Communication record
  def self.send_password_reset_email(buyer_access)
    # Generate the token first
    buyer_access.generate_reset_token
    
    # Send the email
    mail = BuyerPortalMailer.password_reset_email(buyer_access).deliver_now
    
    # Create Communication record
    communication = Communication.create!(
      communicable: buyer_access.buyer,
      direction: 'outbound',
      channel: 'email',
      provider: 'smtp',
      status: 'sent',
      subject: "Reset Your #{ENV.fetch('COMPANY_NAME', 'RenterInsight')} Portal Password",
      body: "Password reset email sent to #{buyer_access.email}. Link expires in 1 hour.",
      from_address: ENV.fetch('PORTAL_FROM_EMAIL', 'portal@renterinsight.com'),
      to_address: buyer_access.email,
      portal_visible: false,
      sent_at: Time.current,
      metadata: {
        'email_type' => 'password_reset',
        'buyer_access_id' => buyer_access.id,
        'token_expires_at' => buyer_access.reset_token_expires_at,
        'message_id' => mail.message_id
      }
    )
    
    communication.mark_as_sent!
    
    Rails.logger.info "[BuyerPortalService] Password reset sent to: #{buyer_access.email}"
    Rails.logger.info "[BuyerPortalService] Token expires at: #{buyer_access.reset_token_expires_at}"
    communication
  end
  
  # Send quote acceptance confirmation email
  def self.send_quote_acceptance_email(quote, buyer_access)
    # Send the email
    mail = BuyerPortalMailer.quote_acceptance_email(quote, buyer_access).deliver_now
    
    # Create Communication record
    communication = Communication.create!(
      communicable: quote,
      direction: 'outbound',
      channel: 'email',
      provider: 'smtp',
      status: 'sent',
      subject: "Quote #{quote.quote_number} Accepted - Thank You!",
      body: "Quote acceptance confirmation sent to #{buyer_access.email}. Total: $#{sprintf('%.2f', quote.total)}",
      from_address: ENV.fetch('PORTAL_FROM_EMAIL', 'portal@renterinsight.com'),
      to_address: buyer_access.email,
      portal_visible: true,
      sent_at: Time.current,
      metadata: {
        'email_type' => 'quote_acceptance',
        'quote_id' => quote.id,
        'quote_number' => quote.quote_number,
        'quote_total' => quote.total,
        'buyer_access_id' => buyer_access.id,
        'message_id' => mail.message_id
      }
    )
    
    communication.mark_as_sent!
    
    Rails.logger.info "[BuyerPortalService] Quote acceptance email sent for: #{quote.quote_number}"
    communication
  end
  
  # Notify internal team of quote rejection
  def self.notify_quote_rejection(quote, buyer_access)
    # Send the email to internal team
    mail = BuyerPortalMailer.quote_rejection_notification(quote, buyer_access).deliver_now
    
    # Create Communication record (internal notification, not portal visible)
    communication = Communication.create!(
      communicable: quote,
      direction: 'outbound',
      channel: 'email',
      provider: 'smtp',
      status: 'sent',
      subject: "Quote #{quote.quote_number} Rejected by #{buyer_access.buyer.full_name rescue buyer_access.email}",
      body: "Internal notification: Quote #{quote.quote_number} was rejected by #{buyer_access.email}. Total: $#{sprintf('%.2f', quote.total)}",
      from_address: ENV.fetch('PORTAL_FROM_EMAIL', 'portal@renterinsight.com'),
      to_address: ENV.fetch('SALES_EMAIL', 'sales@renterinsight.com'),
      portal_visible: false,
      sent_at: Time.current,
      metadata: {
        'email_type' => 'quote_rejection_internal',
        'quote_id' => quote.id,
        'quote_number' => quote.quote_number,
        'quote_total' => quote.total,
        'buyer_access_id' => buyer_access.id,
        'rejected_by' => buyer_access.email,
        'message_id' => mail.message_id
      }
    )
    
    communication.mark_as_sent!
    
    Rails.logger.info "[BuyerPortalService] Quote rejection notification sent for: #{quote.quote_number}"
    communication
  end
  
  # Notify internal team of buyer reply in portal
  def self.notify_internal_of_reply(communication)
    buyer = communication.communicable
    
    # Send internal notification email
    mail = BuyerPortalMailer.communication_reply_notification(communication).deliver_now
    
    # Create Communication record for the notification
    notification = Communication.create!(
      communicable: buyer,
      direction: 'outbound',
      channel: 'email',
      provider: 'smtp',
      status: 'sent',
      subject: "New Reply from #{buyer.full_name rescue buyer.email} in Portal",
      body: "Internal notification: New message received in portal from #{buyer.email rescue 'buyer'}. Original message: #{communication.body.truncate(200)}",
      from_address: ENV.fetch('PORTAL_FROM_EMAIL', 'portal@renterinsight.com'),
      to_address: ENV.fetch('SUPPORT_EMAIL', 'support@renterinsight.com'),
      portal_visible: false,
      sent_at: Time.current,
      metadata: {
        'email_type' => 'reply_notification_internal',
        'original_communication_id' => communication.id,
        'thread_id' => communication.communication_thread_id,
        'message_id' => mail.message_id
      }
    )
    
    notification.mark_as_sent!
    
    Rails.logger.info "[BuyerPortalService] Reply notification sent for thread: #{communication.communication_thread_id}"
    notification
  end
end
