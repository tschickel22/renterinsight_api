# frozen_string_literal: true

# Service to handle activity notifications (email, SMS, popup)
# Uses the same settings pattern as communications
class ActivityNotificationService
  def initialize(activity)
    @activity = activity
    @lead = activity.lead
    @assigned_user = activity.assigned_to
  end

  def send_all_notifications
    settings = get_notification_settings
    
    send_email_notification if should_send_email?(settings)
    send_sms_notification if should_send_sms?(settings)
    send_popup_notification if should_send_popup?(settings)
  end

  def send_reminder_notifications
    settings = get_notification_settings
    
    @activity.reminder_method&.each do |method|
      case method
      when 'email'
        send_email_notification if settings.dig(:email, :isEnabled)
      when 'popup'
        send_popup_notification if settings.dig(:popup, :isEnabled)
      when 'sms'
        send_sms_notification if settings.dig(:sms, :isEnabled)
      end
    end
  end

  private

  def get_notification_settings
    # Company settings override platform settings (same pattern as communications)
    company = @lead.converted_account&.company || Company.first
    
    company_settings = company&.notifications_settings
    return symbolize_keys(company_settings) if company_settings.present?
    
    # Fall back to platform defaults
    default_platform_settings
  end

  def symbolize_keys(hash)
    return hash unless hash.is_a?(Hash)
    hash.deep_symbolize_keys rescue hash
  end

  def default_platform_settings
    {
      email: { isEnabled: true, sendReminders: true, sendActivityUpdates: true },
      sms: { isEnabled: false, sendReminders: true, sendUrgentOnly: true },
      popup: { isEnabled: true, showReminders: true, showActivityUpdates: true, autoClose: true, autoCloseDelay: 5000 }
    }
  end

  def should_send_email?(settings)
    return false unless settings.dig(:email, :isEnabled)
    return false unless @assigned_user&.email.present?
    
    if @activity.activity_type == 'reminder'
      settings.dig(:email, :sendReminders)
    else
      settings.dig(:email, :sendActivityUpdates)
    end
  end

  def should_send_sms?(settings)
    return false unless settings.dig(:sms, :isEnabled)
    # Check if user has phone number
    return false unless @assigned_user.respond_to?(:phone) && @assigned_user.phone.present? rescue false
    
    if @activity.activity_type == 'reminder'
      settings.dig(:sms, :sendReminders)
    else
      # Only send SMS for urgent activities if sendUrgentOnly is true
      return false if settings.dig(:sms, :sendUrgentOnly) && @activity.priority != 'urgent'
      true
    end
  end

  def should_send_popup?(settings)
    return false unless settings.dig(:popup, :isEnabled)
    
    if @activity.activity_type == 'reminder'
      settings.dig(:popup, :showReminders)
    else
      settings.dig(:popup, :showActivityUpdates)
    end
  end

  def send_email_notification
    # Use ActionMailer to send email
    ActivityMailer.activity_notification(@activity, @assigned_user).deliver_later
    Rails.logger.info "[ActivityNotification] Queued email for activity #{@activity.id} to #{@assigned_user&.email}"
  rescue => e
    Rails.logger.error "[ActivityNotification] Failed to send email: #{e.message}"
  end

  def send_sms_notification
    # Use Twilio or configured SMS provider
    sms_settings = get_sms_settings
    
    if sms_settings[:provider] == 'twilio' && sms_settings[:isEnabled]
      TwilioService.send_activity_sms(@activity, @assigned_user)
      Rails.logger.info "[ActivityNotification] Sent SMS for activity #{@activity.id}"
    else
      Rails.logger.info "[ActivityNotification] SMS not configured or disabled"
    end
  rescue => e
    Rails.logger.error "[ActivityNotification] Failed to send SMS: #{e.message}"
  end

  def send_popup_notification
    # Use ActionCable for real-time popup notifications
    return unless @assigned_user

    # Get popup settings - with proper defaults
    all_settings = get_notification_settings
    popup_settings = all_settings.dig(:popup) || default_platform_settings[:popup]

    ActionCable.server.broadcast(
      "user_notifications_#{@assigned_user.id}",
      {
        type: 'activity_notification',
        activity: {
          id: @activity.id,
          type: @activity.activity_type,
          subject: @activity.subject,
          description: @activity.description,
          priority: @activity.priority,
          dueDate: @activity.due_date&.iso8601,
          leadName: "#{@lead.first_name} #{@lead.last_name}",
          leadId: @lead.id
        },
        settings: popup_settings
      }
    )
    
    Rails.logger.info "[ActivityNotification] Broadcast popup for activity #{@activity.id} to user #{@assigned_user.id}"
  rescue => e
    Rails.logger.error "[ActivityNotification] Failed to send popup: #{e.message}"
    Rails.logger.error e.backtrace.join("\n")
  end

  def get_sms_settings
    company = @lead.converted_account&.company || Company.first
    comm_settings = company&.communications_settings
    
    if comm_settings && comm_settings[:sms]
      symbolize_keys(comm_settings[:sms])
    else
      { provider: 'twilio', isEnabled: false }
    end
  end
end
