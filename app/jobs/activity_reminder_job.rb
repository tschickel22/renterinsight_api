# frozen_string_literal: true

class ActivityReminderJob < ApplicationJob
  queue_as :default
  
  def perform(activity_id, activity_type = 'LeadActivity')
    # Support LeadActivity, ContactActivity, and AccountActivity
    activity = case activity_type
               when 'ContactActivity'
                 ContactActivity.find_by(id: activity_id)
               when 'AccountActivity'
                 AccountActivity.find_by(id: activity_id)
               when 'LeadActivity'
                 LeadActivity.find_by(id: activity_id)
               else
                 # Fallback to LeadActivity for backward compatibility
                 LeadActivity.find_by(id: activity_id)
               end
    
    return unless activity && !activity.reminder_sent
    
    Rails.logger.info "[ActivityReminderJob] Sending reminders for #{activity_type} #{activity_id}"
    
    # Use the notification service to send reminders
    ActivityNotificationService.new(activity).send_reminder_notifications
    
    # Don't mark as sent here - let the frontend mark it when displayed
    # This allows polling API to act as fallback if ActionCable broadcast fails
  rescue => e
    Rails.logger.error "[ActivityReminderJob] Failed to send reminders for #{activity_type} #{activity_id}: #{e.message}"
    Rails.logger.error e.backtrace.join("\n")
  end
end
