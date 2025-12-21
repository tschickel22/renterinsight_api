# app/services/activity_reminder_service.rb
class ActivityReminderService
  def self.send_reminder(activity)
    user = activity.assigned_to || activity.user
    return unless user
    
    # Get user's notification preferences
    settings = user.notification_settings || {}
    entity_type = determine_entity_type(activity)
    reminder_settings = settings.dig("#{entity_type}_reminders")
    
    # Fallback to activity_reminders if entity-specific not found
    reminder_settings ||= settings.dig('activity_reminders')
    
    # Default to enabled if no settings
    return unless reminder_settings.nil? || reminder_settings.dig('enabled') != false
    
    channels = reminder_settings&.dig('channels') || {
      'bell' => true,
      'popup' => true,
      'email' => false,
      'sms' => false
    }
    
    Rails.logger.info("[ActivityReminderService] Sending reminder for #{entity_type} activity #{activity.id} to user #{user.id}")
    Rails.logger.info("[ActivityReminderService] Channels: #{channels.inspect}")
    
    # Send via enabled channels
    notification = send_bell_notification(activity, user) if channels['bell']
    send_popup_notification(activity, user) if channels['popup']
    
    # Email and SMS need the notification object from bell notification
    # If bell notification is disabled, create one just for email/SMS delivery
    if (channels['email'] || channels['sms']) && notification.nil?
      notification = create_notification_without_bell(activity, user)
    end
    
    send_email_reminder(notification, user) if channels['email'] && notification
    send_sms_reminder(notification, user) if channels['sms'] && notification
    
    # Mark as sent
    activity.update!(reminder_sent: true)
  rescue => e
    Rails.logger.error("[ActivityReminderService] Error sending reminder: #{e.message}")
    Rails.logger.error(e.backtrace.join("\n"))
  end
  
  private
  
  def self.determine_entity_type(activity)
    # Determine entity type from activity class or polymorphic association
    if activity.class.name.include?('Lead')
      'lead'
    elsif activity.class.name.include?('Contact')
      'contact'
    elsif activity.class.name.include?('Account')
      'account'
    elsif activity.respond_to?(:entity_type)
      activity.entity_type.downcase
    else
      'activity'
    end
  end
  
  def self.send_bell_notification(activity, user)
    # Create persistent notification in bell icon
    notification = build_notification(activity, user)
    
    if notification.save
      Rails.logger.info("[ActivityReminderService] Bell notification created for user #{user.id}")
      return notification
    else
      Rails.logger.error("[ActivityReminderService] Error creating bell notification: #{notification.errors.full_messages.join(', ')}")
      return nil
    end
  rescue => e
    Rails.logger.error("[ActivityReminderService] Error creating bell notification: #{e.message}")
    Rails.logger.error(e.backtrace.join("\n"))
    return nil
  end
  
  def self.create_notification_without_bell(activity, user)
    # Create notification for email/SMS only (not stored for bell icon)
    # This is used when bell notifications are disabled but email/SMS are enabled
    notification = build_notification(activity, user)
    
    if notification.save
      Rails.logger.info("[ActivityReminderService] Notification created for email/SMS delivery")
      return notification
    else
      Rails.logger.error("[ActivityReminderService] Error creating notification: #{notification.errors.full_messages.join(', ')}")
      return nil
    end
  rescue => e
    Rails.logger.error("[ActivityReminderService] Error creating notification: #{e.message}")
    return nil
  end
  
  def self.build_notification(activity, user)
    # Determine the notifiable entity (Lead, Contact, or Account)
    notifiable = if activity.respond_to?(:lead) && activity.lead
      activity.lead
    elsif activity.respond_to?(:contact) && activity.contact
      activity.contact
    elsif activity.respond_to?(:account) && activity.account
      activity.account
    else
      nil
    end
    
    # Get company_id for tenant scoping
    company_id = notifiable&.company_id || user.company_id
    
    # Map activity priority to notification priority
    notification_priority = case activity.priority&.downcase
    when 'high', 'urgent'
      'high'
    when 'low'
      'low'
    else
      'normal'
    end
    
    # Build detailed message with entity context
    entity_name = get_entity_name(activity)
    entity_type = determine_entity_type(activity).titleize
    
    message = if activity.description.present?
      "#{activity.description}\n\nRelated to: #{entity_name} (#{entity_type})"
    else
      "Activity reminder for #{entity_name} (#{entity_type})"
    end
    
    # Build action URL to view the entity directly
    action_url = if notifiable.present?
      case notifiable.class.name
      when 'Lead'
        "/crm/leads/#{notifiable.id}?tab=activities"
      when 'Contact'
        "/contacts/#{notifiable.id}?tab=activities"
      when 'Account'
        "/accounts/#{notifiable.id}?tab=activities"
      else
        nil
      end
    end
    
    action_text = if notifiable.present?
      "View #{entity_type}"
    else
      'View Details'
    end
    
    Notification.new(
      recipient: user,
      notifiable: notifiable,
      company_id: company_id,
      notification_type: 'activity_reminder',
      category: 'crm',
      priority: notification_priority,
      title: activity.subject || 'Activity Reminder',
      message: message,
      action_url: action_url,
      action_text: action_text,
      metadata: {
        activity_id: activity.id,
        activity_type: activity.activity_type,
        due_date: activity.due_date || activity.reminder_time,
        priority: activity.priority,
        entity_name: entity_name,
        entity_type: entity_type
      },
      read: false
    )
  end
  
  def self.send_popup_notification(activity, user)
    Rails.logger.info("[ActivityReminderService] START send_popup_notification for #{determine_entity_type(activity)} activity #{activity.id}")
    
    # Broadcast via ActionCable for real-time toast
    entity_name = get_entity_name(activity)
    entity_type = determine_entity_type(activity)
    
    # Determine entity ID based on type
    entity_id = case entity_type
    when 'lead'
      activity.lead_id if activity.respond_to?(:lead_id)
    when 'contact'
      activity.contact_id if activity.respond_to?(:contact_id)
    when 'account'
      activity.account_id if activity.respond_to?(:account_id)
    end
    
    Rails.logger.info("[ActivityReminderService] Popup data: entity_type=#{entity_type}, entity_id=#{entity_id}, entity_name=#{entity_name}")
    
    # Build the broadcast payload with both old and new formats for compatibility
    broadcast_data = {
      type: 'activity_notification',
      activity: {
        id: activity.id,
        type: activity.activity_type,
        subject: activity.subject,
        description: activity.description || activity.notes,
        priority: activity.priority,
        due_date: activity.due_date || activity.reminder_time,
        # Old format (for backward compatibility)
        leadName: entity_name,
        leadId: (entity_type == 'lead' ? entity_id : nil),
        # New format (unified)
        entityName: entity_name,
        entityType: entity_type,
        entityId: entity_id
      },
      settings: {
        isEnabled: true,
        showReminders: true,
        showActivityUpdates: true,
        autoClose: true,
        autoCloseDelay: 5000
      }
    }
    
    Rails.logger.info("[ActivityReminderService] Broadcasting to channel: user_notifications_#{user.id}")
    Rails.logger.info("[ActivityReminderService] Broadcast data: #{broadcast_data.inspect}")
    
    ActionCable.server.broadcast(
      "user_notifications_#{user.id}",
      broadcast_data
    )
    
    Rails.logger.info("[ActivityReminderService] Popup notification broadcast COMPLETE for user #{user.id}")
  rescue => e
    Rails.logger.error("[ActivityReminderService] Error broadcasting popup: #{e.message}")
    Rails.logger.error(e.backtrace.join("\n"))
  end
  
  def self.send_email_reminder(notification, user)
    # Send email notification through universal NotificationService
    return unless user.email.present?
    return unless notification.is_a?(Notification)
    
    begin
      NotificationService.send_email(notification, user)
      Rails.logger.info("[ActivityReminderService] Email sent to #{user.email}")
    rescue => e
      Rails.logger.error("[ActivityReminderService] Error sending email: #{e.message}")
      Rails.logger.error(e.backtrace.join("\n"))
    end
  end
  
  def self.send_sms_reminder(notification, user)
    # Send SMS notification through universal NotificationService
    return unless user.phone.present?
    return unless notification.is_a?(Notification)
    
    begin
      NotificationService.send_sms(notification, user)
      Rails.logger.info("[ActivityReminderService] SMS sent to #{user.phone}")
    rescue => e
      Rails.logger.error("[ActivityReminderService] Error sending SMS: #{e.message}")
      Rails.logger.error(e.backtrace.join("\n"))
    end
  end
  
  def self.get_entity_name(activity)
    if activity.respond_to?(:lead) && activity.lead
      "#{activity.lead.first_name} #{activity.lead.last_name}".strip
    elsif activity.respond_to?(:contact) && activity.contact
      "#{activity.contact.first_name} #{activity.contact.last_name}".strip
    elsif activity.respond_to?(:account) && activity.account
      activity.account.name
    else
      'Unknown'
    end
  end
end
