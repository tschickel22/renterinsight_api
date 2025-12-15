# app/controllers/concerns/notification_triggers.rb
module NotificationTriggers
  extend ActiveSupport::Concern
  
  # Trigger a notification with smart defaults
  # Usage: trigger_notification(:quote_accepted, recipient: user, notifiable: quote)
  def trigger_notification(type, recipient:, notifiable: nil, **options)
    # Get default settings for this notification type
    defaults = Notification::TYPES[type.to_sym]
    
    unless defaults
      Rails.logger.warn "[NotificationTriggers] Unknown notification type: #{type}"
      return nil
    end
    
    # Build notification params with smart defaults
    params = {
      recipient: recipient,
      notification_type: type,
      title: options[:title] || defaults[:title],
      message: options[:message],
      category: options[:category] || defaults[:category],
      priority: options[:priority] || defaults[:priority],
      notifiable: notifiable,
      action_url: options[:action_url],
      action_text: options[:action_text],
      actor: options[:actor] || current_user,
      company_id: options[:company_id] || @company&.id || recipient.company_id,
      location_id: options[:location_id],
      deliver_now: options[:deliver_now].nil? ? true : options[:deliver_now]
    }
    
    # Auto-generate action URL if not provided and notifiable exists
    if notifiable.present? && params[:action_url].blank?
      params[:action_url] = auto_action_url(notifiable)
    end
    
    # Auto-generate action text if not provided
    if params[:action_url].present? && params[:action_text].blank?
      params[:action_text] = auto_action_text(notifiable)
    end
    
    # Create the notification
    NotificationService.create(params)
  rescue => e
    Rails.logger.error "[NotificationTriggers] Failed to create notification: #{e.message}"
    Rails.logger.error e.backtrace.first(5).join("\n")
    nil
  end
  
  # Trigger notification for multiple recipients
  def trigger_notifications(type, recipients:, **options)
    recipients.each do |recipient|
      trigger_notification(type, recipient: recipient, **options)
    end
  end
  
  private
  
  def auto_action_url(notifiable)
    case notifiable.class.name
    when 'ServiceTicket'
      "/service/tickets/#{notifiable.id}"
    when 'Lead'
      "/crm/leads/#{notifiable.id}"
    when 'Deal'
      "/deals/#{notifiable.id}"
    when 'Quote'
      "/quotes/#{notifiable.id}"
    when 'Payment'
      "/finance/payments/#{notifiable.id}"
    when 'Invoice'
      "/finance/invoices/#{notifiable.id}"
    when 'Contact'
      "/contacts/#{notifiable.id}"
    when 'Account'
      "/accounts/#{notifiable.id}"
    when 'Task', 'ContactActivity'
      "/tasks/#{notifiable.id}"
    when 'Communication'
      "/portal/messages"
    else
      nil
    end
  end
  
  def auto_action_text(notifiable)
    case notifiable.class.name
    when 'ServiceTicket'
      'View Ticket'
    when 'Lead'
      'View Lead'
    when 'Deal'
      'View Deal'
    when 'Quote'
      'View Quote'
    when 'Payment'
      'View Payment'
    when 'Invoice'
      'View Invoice'
    when 'Contact'
      'View Contact'
    when 'Account'
      'View Account'
    when 'Task', 'ContactActivity'
      'View Task'
    when 'Communication'
      'View Messages'
    else
      'View Details'
    end
  end
end
