# frozen_string_literal: true

class ActivityReminderJob < ApplicationJob
  queue_as :default
  
  def perform(activity_id)
    activity = LeadActivity.find_by(id: activity_id)
    return unless activity && !activity.reminder_sent
    
    Rails.logger.info "[ActivityReminderJob] Sending reminders for activity #{activity_id}"
    
    # Use the notification service to send reminders
    ActivityNotificationService.new(activity).send_reminder_notifications
    
    # Mark as sent
    activity.update!(reminder_sent: true)
  rescue => e
    Rails.logger.error "[ActivityReminderJob] Failed to send reminders for activity #{activity_id}: #{e.message}"
  end
end
