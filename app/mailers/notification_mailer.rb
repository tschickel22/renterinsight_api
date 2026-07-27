# app/mailers/notification_mailer.rb
class NotificationMailer < ApplicationMailer
  def broadcast_notification(user:, notification:)
    @user = user
    @notification = notification
    
    # Use broadcasting company for email settings (for cross-company broadcasts)
    broadcasting_company_id = notification.metadata['broadcasting_company_id'] || notification.company_id
    @company = Company.find_by(id: broadcasting_company_id) if broadcasting_company_id.present?
    @location = Location.find_by(id: notification.location_id) if notification.location_id.present?
    
    # Get frontend URL for links - respects FRONTEND_URL env var for staging/production
    @frontend_url = ENV['FRONTEND_URL'] || 
                    (Rails.env.production? ? 'https://app.renterinsight.com' : 'https://localhost:5173')
    
    Rails.logger.info "[NotificationMailer] Frontend URL: #{@frontend_url}"
    Rails.logger.info "[NotificationMailer] Action URL: #{notification.action_url}"
    
    # Build action button if action_url present
    @action_url = notification.action_url
    @action_text = notification.action_text || 'View Details'
    
    # Determine category icon/color
    @category_config = {
      'system' => { icon: '⚙️', color: '#6b7280' },
      'assignment' => { icon: '📋', color: '#3b82f6' },
      'activity' => { icon: '🔔', color: '#8b5cf6' },
      'communication' => { icon: '💬', color: '#06b6d4' },
      'financial' => { icon: '💰', color: '#10b981' },
      'alert' => { icon: '⚠️', color: '#f59e0b' },
      'service' => { icon: '🔧', color: '#ec4899' },
      'crm' => { icon: '👥', color: '#14b8a6' },
      'sales' => { icon: '💼', color: '#8b5cf6' },
      'finance' => { icon: '💰', color: '#10b981' },
      'broadcast' => { icon: '📢', color: '#f59e0b' }
    }[@notification.category] || { icon: '🔔', color: '#6b7280' }
    
    # Attach files if present
    if notification.attachments.attached?
      notification.attachments.each do |attachment|
        attachments[attachment.filename.to_s] = attachment.download
      end
    end
    
    mail(
      to: @user.email,
      from: default_from_address,
      subject: notification.title
    )
  end

  # Relays the recipient's reply to the rep so they can carry on the conversation straight
  # from their inbox. Replies are captured back into Renter Insight by the Gmail/Outlook
  # sent-email polling, so no "view in app" round-trip is required.
  def email_reply(user:, entity_name:, entity_type:, from_address:, subject:, preview:, link:, reply_to_address: nil, body_html: nil, to_address: nil)
    @user = user
    @entity_name = entity_name
    @entity_type = entity_type
    @from_address = from_address
    @subject = subject
    @preview = preview
    @link = link
    # The actual reply content to relay (falls back to the short preview).
    @reply_body = body_html.presence || preview

    # Split the new text from the quoted original so the rep sees what the
    # person actually wrote up top, with the (often security-rewritten) quoted
    # thread tucked below. And give a one-click "Reply to <them>" mailto so the
    # rep can respond without hunting — Reply-To makes plain Reply work too.
    cleaned = InboundEmail::ReplyBodyCleaner.split(@reply_body)
    @reply_clean = cleaned.reply
    @reply_quoted = cleaned.quoted
    @reply_to_email = reply_to_address.presence || from_address
    reply_subject_line = @subject.to_s.match?(/\Are:/i) ? @subject.to_s : "Re: #{@subject}"
    @reply_mailto = ("mailto:#{@reply_to_email}?subject=#{ERB::Util.url_encode(reply_subject_line)}" if @reply_to_email.present?)

    # Get frontend URL
    @frontend_url = ENV['FRONTEND_URL'] ||
                    (Rails.env.production? ? 'https://app.renterinsight.com' : 'https://staging.crm.landlordinsight.com')

    # Full link with domain
    @full_link = "#{@frontend_url}#{@link}"

    # Resolve per-send provider creds from communications settings (the SES-authorized
    # keys), matching InvoiceMailer/SocialPostMailer. Without this the mailer falls back to
    # the boot-time global delivery method, which used the wrong (S3-only) ENV AWS creds and
    # failed SES with AccessDenied.
    delivery = MailerDeliveryConfigurator.resolve(company: @user.try(:company))

    # Use the reply's own subject so it threads naturally; show the contact as the sender
    # name (SES still sends from the verified identity), and Reply-To = the contact so a
    # plain "Reply" in the rep's inbox goes straight to them.
    relay_subject = @subject.presence || "Reply from #{@entity_name}"
    # Deliver to the original sending mailbox (the rep's connected inbox) when provided,
    # so they reply in place and the sent-email polling captures it; else the account email.
    mail_options = { to: (to_address.presence || @user.email), subject: relay_subject }
    mail_options[:reply_to] = reply_to_address if reply_to_address.present?
    from_email = delivery && delivery[:from_address].presence
    mail_options[:from] = from_email.present? ? "#{@entity_name} <#{from_email}>" : default_from_address

    message = mail(mail_options)
    message.delivery_method(delivery[:delivery_method], delivery[:delivery_method_options]) if delivery && message
    message
  end
end
