# app/jobs/send_activity_reminders_job.rb
class SendActivityRemindersJob < ApplicationJob
  queue_as :default
  
  def perform
    Rails.logger.info("[SendActivityRemindersJob] Starting activity reminder check")
    
    # Find all activities with reminders due in next 5 minutes
    lead_count = process_lead_reminders
    contact_count = process_contact_reminders
    account_count = process_account_reminders
    
    Rails.logger.info("[SendActivityRemindersJob] Completed: #{lead_count} lead, #{contact_count} contact, #{account_count} account reminders sent")
  end
  
  private
  
  def process_lead_reminders
    return 0 unless defined?(LeadActivity)
    
    count = 0
    LeadActivity.where(activity_type: 'reminder')
                .where('reminder_time <= ?', 5.minutes.from_now)
                .where('reminder_time > ?', Time.current)
                .where(reminder_sent: [false, nil])
                .find_each do |activity|
      ActivityReminderService.send_reminder(activity)
      count += 1
    end
    count
  rescue => e
    Rails.logger.error("[SendActivityRemindersJob] Error processing lead reminders: #{e.message}")
    0
  end
  
  def process_contact_reminders
    return 0 unless defined?(ContactActivity)
    
    count = 0
    ContactActivity.where(activity_type: 'reminder')
                   .where('reminder_time <= ?', 5.minutes.from_now)
                   .where('reminder_time > ?', Time.current)
                   .where(reminder_sent: [false, nil])
                   .find_each do |activity|
      ActivityReminderService.send_reminder(activity)
      count += 1
    end
    count
  rescue => e
    Rails.logger.error("[SendActivityRemindersJob] Error processing contact reminders: #{e.message}")
    0
  end
  
  def process_account_reminders
    return 0 unless defined?(AccountActivity)
    
    count = 0
    AccountActivity.where(activity_type: 'reminder')
                   .where('reminder_time <= ?', 5.minutes.from_now)
                   .where('reminder_time > ?', Time.current)
                   .where(reminder_sent: [false, nil])
                   .find_each do |activity|
      ActivityReminderService.send_reminder(activity)
      count += 1
    end
    count
  rescue => e
    Rails.logger.error("[SendActivityRemindersJob] Error processing account reminders: #{e.message}")
    0
  end
end
