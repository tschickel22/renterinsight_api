# app/services/notification_service.rb
class NotificationService
  # Create a notification and optionally deliver it
  def self.create(recipient:, notification_type:, notifiable: nil, actor: nil, message: nil, deliver_now: false, **options)
    # Get notification type configuration
    type_config = Notification::TYPES[notification_type.to_sym]
    return nil unless type_config
    
    # Store broadcasting company context in metadata for email/SMS
    broadcasting_company_id = options[:company_id] || Current.company&.id
    metadata = options[:metadata] || {}
    metadata[:broadcasting_company_id] = broadcasting_company_id if broadcasting_company_id.present?
    
    # Extract attachments from options
    attachments = options.delete(:attachments) || []
    
    # Build notification
    notification = Notification.new(
      recipient: recipient,
      notification_type: notification_type.to_s,
      category: type_config[:category],
      priority: options[:priority] || type_config[:priority],
      title: options[:title] || type_config[:title],
      message: message || build_default_message(notification_type, notifiable, actor),
      notifiable: notifiable,
      actor: actor,
      company_id: recipient.company_id,  # ALWAYS use recipient's company for in-app visibility
      location_id: options[:location_id] || Current.location_id,
      action_url: options[:action_url],
      action_text: options[:action_text],
      action_data: options[:action_data] || {},
      metadata: metadata
    )
    
    if notification.save
      # Attach files if provided
      if attachments.present?
        attachments.each do |attachment_file|
          notification.attachments.attach(attachment_file) if attachment_file.present?
        end
      end
      
      # Deliver via email/SMS if requested
      deliver(notification) if deliver_now
      
      notification
    else
      Rails.logger.error("Failed to create notification: #{notification.errors.full_messages.join(', ')}")
      nil
    end
  end
  
  # Broadcast a message to multiple recipients
  def self.broadcast(message:, location_ids: nil, roles: nil, send_email: false, send_sms: false, deliver_now: true, **options)
    # Get company_id from Current context
    company_id = Current.company_id
    unless company_id
      Rails.logger.error "[NotificationService] No company_id in Current context"
      return { success: false, sent_count: 0, error: 'No company context' }
    end
    
    # Extract attachments from options
    attachments = options.delete(:attachments) || []
    
    # Find all matching users
    users = User.where(company_id: company_id, deleted_at: nil)
    Rails.logger.info "[NotificationService] Initial query: #{users.count} users in company #{company_id}"
    
    # Track if we need to include cross-company admins
    cross_company_admin_ids = []
    
    # Filter by locations if specified
    if location_ids.present?
      user_ids = UserLocation.where(location_id: location_ids).pluck(:user_id)
      Rails.logger.info "[NotificationService] Location filter: #{user_ids.count} users in locations #{location_ids}"
      
      # Include platform admins from ANY company (they have global access)
      cross_company_admin_ids = User.where(deleted_at: nil)
                                   .where(role: ['platform_admin', 'super_admin'])
                                   .where.not(company_id: company_id) # Only cross-company
                                   .pluck(:id)
      
      # Company-specific admins for this company
      company_admin_ids = User.where(company_id: company_id, deleted_at: nil)
                             .where(role: ['admin', 'company_admin'])
                             .pluck(:id)
      
      # Combine: location users + company admins (will be filtered from company users)
      combined_user_ids = (user_ids + company_admin_ids).uniq
      Rails.logger.info "[NotificationService] Including #{cross_company_admin_ids.count} platform admins (cross-company) + #{company_admin_ids.count} company admins"
      
      users = users.where(id: combined_user_ids)
    end
    
    # Filter by roles if specified
    if roles.present?
      role_ids = Role.where(key: roles).pluck(:id)
      Rails.logger.info "[NotificationService] Role filter: found #{role_ids.count} roles for keys #{roles}"
      user_ids = UserRoleAssignment.where(role_id: role_ids).pluck(:user_id)
      Rails.logger.info "[NotificationService] Role filter: #{user_ids.count} users with roles #{roles}"
      users = users.where(id: user_ids)
    end
    
    Rails.logger.info "[NotificationService] Final user count after filters: #{users.count}"
    
    # Add cross-company platform admins if location filtering was applied
    if cross_company_admin_ids.any?
      cross_company_admins = User.where(id: cross_company_admin_ids, deleted_at: nil)
      Rails.logger.info "[NotificationService] Adding #{cross_company_admins.count} cross-company platform admins"
      
      # Merge the two user sets
      all_user_ids = users.pluck(:id) + cross_company_admin_ids
      users = User.where(id: all_user_ids.uniq, deleted_at: nil)
      Rails.logger.info "[NotificationService] Total users after adding platform admins: #{users.count}"
    end
    
    # Create notification for each user
    sent_count = 0
    users.find_each do |user|
      Rails.logger.info "[NotificationService] Creating notification for user #{user.id} (#{user.email})"
      
      notification = create(
        recipient: user,
        notification_type: :broadcast_message,
        message: message,
        deliver_now: false,
        company_id: company_id,  # Explicit company_id for cross-company admins
        attachments: attachments,  # Pass attachments to each notification
        **options
      )
      
      if notification
        # Override preference for broadcast delivery channels
        if send_email || send_sms
          deliver_broadcast(notification, send_email: send_email, send_sms: send_sms)
        end
        
        sent_count += 1
      end
    end
    
    Rails.logger.info "[NotificationService] Broadcast complete: sent to #{sent_count} user(s)"
    
    { success: true, sent_count: sent_count }
  end
  
  # Deliver notification via email/SMS based on user preferences
  def self.deliver(notification)
    return unless notification.recipient.is_a?(User)
    
    user = notification.recipient
    
    # Get or create preference
    preference = NotificationPreference.get_or_create_for(user, notification.notification_type)
    return unless preference
    
    # Check if we should deliver now (quiet hours)
    return unless preference.should_deliver_now?
    
    # Send email if enabled
    if preference.email_enabled && user.email.present?
      send_email(notification, user)
    end
    
    # Send SMS if enabled
    if preference.sms_enabled && user.phone.present?
      send_sms(notification, user)
    end
  end
  
  # Deliver broadcast with explicit channel control (overrides user preferences)
  def self.deliver_broadcast(notification, send_email: false, send_sms: false)
    return unless notification.recipient.is_a?(User)
    
    user = notification.recipient
    
    Rails.logger.info "[NotificationService] Delivering broadcast to #{user.email}: send_email=#{send_email}, send_sms=#{send_sms}"
    
    # For broadcasts, OVERRIDE user preferences - admin chose explicit channels
    # Send email if admin selected it AND user has email
    if send_email && user.email.present?
      send_email(notification, user)
      Rails.logger.info "[NotificationService] Sent email to #{user.email}"
    end
    
    # Send SMS if admin selected it AND user has phone
    if send_sms && user.phone.present?
      send_sms(notification, user)
      Rails.logger.info "[NotificationService] Sent SMS to #{user.phone}"
    end
    
    # Log what was NOT sent
    Rails.logger.info "[NotificationService] Email NOT sent (send_email=#{send_email}, has_email=#{user.email.present?})" unless send_email && user.email.present?
    Rails.logger.info "[NotificationService] SMS NOT sent (send_sms=#{send_sms}, has_phone=#{user.phone.present?})" unless send_sms && user.phone.present?
  end
  

  # Service Ticket Notifications
  def self.notify_service_ticket_assigned(ticket:, user:)
    create(
      recipient: user,
      notification_type: :service_ticket_assigned,
      notifiable: ticket,
      title: "Service Ticket Assigned to You",
      message: "Service ticket ##{ticket.id} - #{ticket.title} has been assigned to you",
      action_url: "/service/#{ticket.id}",
      action_text: "View Ticket",
      company_id: ticket.company_id,
      location_id: ticket.location_id,
      deliver_now: true
    )
  end
  
  def self.notify_service_ticket_completed(ticket:, user:)
    create(
      recipient: user,
      notification_type: :service_ticket_completed,
      notifiable: ticket,
      title: "Service Ticket Completed",
      message: "Service ticket ##{ticket.id} - #{ticket.title} has been marked as completed",
      action_url: "/service/#{ticket.id}",
      action_text: "View Ticket",
      company_id: ticket.company_id,
      location_id: ticket.location_id,
      deliver_now: true
    )
  end
  
  def self.notify_service_ticket_started(ticket:, user:)
    create(
      recipient: user,
      notification_type: :service_ticket_updated,
      notifiable: ticket,
      title: "Service Ticket Started",
      message: "Service ticket ##{ticket.id} - #{ticket.title} is now in progress",
      action_url: "/service/#{ticket.id}",
      action_text: "View Ticket",
      company_id: ticket.company_id,
      location_id: ticket.location_id,
      deliver_now: true
    )
  end
  
  def self.notify_customer_ticket_completed(ticket:, contact:)
    # This would notify the customer via their portal access
    # Implement if BuyerPortalAccess notifications are needed
  end
  
  private
  
  # Build a descriptive message with WHO did WHAT context
  # Example: "Tom Schickel accepted quote #2345"
  def self.build_contextual_message(action:, actor:, notifiable: nil, details: nil)
    actor_name = if actor.respond_to?(:full_name)
      actor.full_name
    elsif actor.respond_to?(:name)
      actor.name
    elsif actor.is_a?(User)
      "#{actor.first_name} #{actor.last_name}".strip.presence || actor.email
    else
      'Someone'
    end
    
    notifiable_description = if notifiable.present?
      # Try to get a good description of the notifiable object
      if notifiable.respond_to?(:display_name)
        notifiable.display_name
      elsif notifiable.respond_to?(:number) || notifiable.respond_to?(:quote_number)
        number = notifiable.try(:number) || notifiable.try(:quote_number) || notifiable.try(:invoice_number) || notifiable.try(:ticket_number)
        type = notifiable.class.name.underscore.humanize.downcase
        "#{type} ##{number}"
      elsif notifiable.respond_to?(:title)
        notifiable.title
      elsif notifiable.respond_to?(:name)
        notifiable.name
      else
        notifiable.class.name.underscore.humanize.downcase
      end
    end
    
    # Build the message
    message = "#{actor_name} #{action}"
    message += " #{notifiable_description}" if notifiable_description.present?
    message += " - #{details}" if details.present?
    
    message
  end
  
  def self.build_default_message(notification_type, notifiable, actor)
    actor_name = if actor.is_a?(User)
      "#{actor.first_name} #{actor.last_name}".strip.presence || actor.email
    elsif actor.respond_to?(:name)
      actor.name
    else
      'Someone'
    end
    
    notifiable_name = if notifiable.present?
      if notifiable.respond_to?(:display_name)
        notifiable.display_name
      elsif notifiable.respond_to?(:number) || notifiable.respond_to?(:quote_number)
        number = notifiable.try(:number) || notifiable.try(:quote_number) || notifiable.try(:invoice_number) || notifiable.try(:ticket_number)
        "##{number}"
      elsif notifiable.respond_to?(:title)
        notifiable.title
      elsif notifiable.respond_to?(:name)
        notifiable.name
      else
        'item'
      end
    else
      'item'
    end
    
    case notification_type.to_sym
    when :service_ticket_assigned
      "You have been assigned to service ticket #{notifiable_name} by #{actor_name}"
    when :lead_assigned
      "#{actor_name} assigned lead #{notifiable_name} to you"
    when :task_assigned
      "#{actor_name} assigned you a task: #{notifiable_name}"
    when :quote_accepted
      "#{actor_name} accepted quote #{notifiable_name}"
    when :quote_rejected
      "#{actor_name} rejected quote #{notifiable_name}"
    when :deal_won
      "Congratulations! #{actor_name} marked deal #{notifiable_name} as won"
    when :deal_lost
      "#{actor_name} marked deal #{notifiable_name} as lost"
    when :payment_received
      "Payment received from #{actor_name} for #{notifiable_name}"
    when :invoice_sent
      "#{actor_name} sent invoice #{notifiable_name}"
    when :mention_received
      "#{actor_name} mentioned you in a note on #{notifiable_name}"
    when :comment_added
      "#{actor_name} added a comment on #{notifiable_name}"
    else
      "You have a new notification from #{actor_name}"
    end
  end
  
  def self.send_email(notification, user)
    return unless user.email.present?
    
    begin
      # Use ActionMailer to send email
      NotificationMailer.broadcast_notification(
        user: user,
        notification: notification
      ).deliver_now
      
      notification.update(email_sent: true, email_sent_at: Time.current)
      Rails.logger.info "[NotificationService] Email sent to #{user.email}: #{notification.title}"
    rescue => e
      Rails.logger.error("[NotificationService] Failed to send notification email: #{e.message}")
      Rails.logger.error(e.backtrace.first(5).join("\n"))
    end
  end
  
  def self.frontend_url
    # Get frontend URL with environment-based fallback - respects FRONTEND_URL env var for staging
    ENV['FRONTEND_URL'] || 
      (Rails.env.production? ? 'https://app.renterinsight.com' : 'https://localhost:5173')
  end
  
  def self.send_sms(notification, user)
    return unless user.phone.present?
    
    begin
      # Use broadcasting company for SMS settings (for cross-company broadcasts)
      broadcasting_company_id = notification.metadata['broadcasting_company_id'] || notification.company_id
      company = broadcasting_company_id ? Company.find_by(id: broadcasting_company_id) : nil
      
      # Initialize Twilio provider with broadcasting company context
      provider = Providers::Sms::TwilioProvider.new(company: company)
      
      # Build SMS message body
      message_body = "#{notification.title}\n\n#{notification.message}"
      
      # Get frontend URL using helper
      base_url = frontend_url
      
      if notification.action_url.present?
        # Use direct link to the entity/action
        direct_url = "#{base_url}#{notification.action_url}"
        message_body += "\n\n#{notification.action_text || 'View details'}: #{direct_url}"
      elsif notification.attachments.attached?
        # Link to notification center if there are attachments
        notification_url = "#{base_url}/notifications"
        message_body += "\n\nView with attachments: #{notification_url}"
      else
        # Generic notification center link
        notification_url = "#{base_url}/notifications"
        message_body += "\n\nView in app: #{notification_url}"
      end
      
      # Get from_number from location/company waterfall
      location = notification.location_id ? Location.find_by(id: notification.location_id) : nil
      from_number = determine_from_phone(location, company)
      
      # Send SMS (Twilio has 1600 character limit)
      result = provider.send_message(
        to: user.phone,
        from: from_number,
        body: message_body.truncate(1600)
      )
      
      if result[:success]
        notification.update(
          sms_sent: true, 
          sms_sent_at: Time.current,
          metadata: notification.metadata.merge(sms_external_id: result[:external_id])
        )
        Rails.logger.info "[NotificationService] SMS sent to #{user.phone}: #{notification.title}"
      end
    rescue Providers::Sms::TwilioProvider::ConfigurationError => e
      Rails.logger.error("[NotificationService] Twilio not configured: #{e.message}")
    rescue Providers::Sms::TwilioProvider::DeliveryError => e
      Rails.logger.error("[NotificationService] SMS delivery failed: #{e.message}")
    rescue => e
      Rails.logger.error("[NotificationService] Failed to send SMS: #{e.message}")
      Rails.logger.error(e.backtrace.first(5).join("\n"))
    end
  end
  
  def self.determine_from_email(location, company)
    # 1. Try location communication settings first
    if location.present?
      location_setting = Setting.find_by(key: 'communications', scope_type: 'Location', scope_id: location.id)
      if location_setting&.value.present?
        location_data = location_setting.value.is_a?(Hash) ? location_setting.value : JSON.parse(location_setting.value)
        from_email = location_data.dig('email', 'fromEmail')
        return from_email if from_email.present?
      end
    end
    
    # 2. Fall back to company → platform waterfall via CommunicationSettingsService
    settings_service = company ? 
      CommunicationSettingsService.for_company(company) : 
      CommunicationSettingsService.platform
    
    settings_service.email_config[:from_email]
  end
  
  def self.determine_from_phone(location, company)
    # 1. Try location communication settings first
    if location.present?
      location_setting = Setting.find_by(key: 'communications', scope_type: 'Location', scope_id: location.id)
      if location_setting&.value.present?
        location_data = location_setting.value.is_a?(Hash) ? location_setting.value : JSON.parse(location_setting.value)
        from_number = location_data.dig('sms', 'fromNumber')
        return from_number if from_number.present?
      end
    end
    
    # 2. Fall back to company → platform waterfall via CommunicationSettingsService
    settings_service = company ? 
      CommunicationSettingsService.for_company(company) : 
      CommunicationSettingsService.platform
    
    settings_service.sms_config[:from_number]
  end
end
