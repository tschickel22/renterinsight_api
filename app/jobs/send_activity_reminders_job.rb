# app/jobs/send_activity_reminders_job.rb
#
# Fires reminders on lead/contact/account/deal activities whose reminder_time
# is coming up. Scheduled by SolidQueue every minute via config/recurring.yml.
#
# Filter design:
#   - Upper bound: reminder_time <= 5.minutes.from_now
#     Sends the reminder up to 5 minutes early so the "5 minutes before due"
#     UX from the docs holds even when the job's tick lands mid-minute.
#   - Lower bound: reminder_time >= 24.hours.ago
#     PAST-DUE reminders in the last 24 hours DO get sent — this is the fix
#     for the silent-drop bug where a missed tick permanently dropped the
#     reminder. Anything older than 24 hours is considered stale and gets
#     ignored so a long outage doesn't burst-send a week of forgotten
#     reminders when the service comes back.
#   - reminder_sent = false (or nil for legacy rows).
class SendActivityRemindersJob < ApplicationJob
  queue_as :default

  # How far in the future to look ahead (send slightly early so the
  # scheduling tick jitter doesn't miss the exact minute).
  LOOKAHEAD = 5.minutes
  # Send past-due reminders within this window — but not older, so a long
  # outage doesn't dump a week of forgotten reminders in one burst.
  MAX_LATE = 24.hours

  def perform
    Rails.logger.info("[SendActivityRemindersJob] Starting activity reminder check")

    lead_count    = process_reminders(LeadActivity)    if defined?(LeadActivity)
    contact_count = process_reminders(ContactActivity) if defined?(ContactActivity)
    account_count = process_reminders(AccountActivity) if defined?(AccountActivity)
    deal_count    = process_reminders(DealActivity)    if defined?(DealActivity)

    Rails.logger.info("[SendActivityRemindersJob] Completed: #{lead_count.to_i} lead, #{contact_count.to_i} contact, #{account_count.to_i} account, #{deal_count.to_i} deal reminders sent")
  end

  private

  def process_reminders(klass)
    count = 0
    klass.where(activity_type: 'reminder')
         .where('reminder_time <= ?', LOOKAHEAD.from_now)
         .where('reminder_time >= ?', MAX_LATE.ago)
         .where(reminder_sent: [false, nil])
         .find_each do |activity|
      ActivityReminderService.send_reminder(activity)
      count += 1
    end
    count
  rescue => e
    Rails.logger.error("[SendActivityRemindersJob] Error processing #{klass} reminders: #{e.message}")
    0
  end
end
