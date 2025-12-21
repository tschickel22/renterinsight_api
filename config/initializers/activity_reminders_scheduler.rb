# config/initializers/activity_reminders_scheduler.rb
#
# This initializer schedules the SendActivityRemindersJob to run every minute.
# 
# For production, you should use a proper scheduler like:
# - Heroku Scheduler
# - Render Cron Jobs
# - whenever gem
# - sidekiq-scheduler
#
# For development/testing, this uses a simple Thread-based scheduler.

if Rails.env.development? || ENV['ENABLE_REMINDER_SCHEDULER'] == 'true'
  Rails.application.config.after_initialize do
    Thread.new do
      loop do
        begin
          # Run the reminder job
          SendActivityRemindersJob.perform_now
        rescue => e
          Rails.logger.error("[ReminderScheduler] Error running reminder job: #{e.message}")
        end
        
        # Wait 1 minute before next run
        sleep 60
      end
    end
  end
end

# PRODUCTION SETUP INSTRUCTIONS:
#
# === Render ===
# Add a Cron Job in Render Dashboard:
# - Schedule: */1 * * * * (every minute)
# - Command: bundle exec rails runner "SendActivityRemindersJob.perform_now"
#
# === Heroku ===
# Use Heroku Scheduler add-on:
# $ heroku addons:create scheduler:standard
# Then add a job in the Heroku dashboard:
# - Frequency: Every 10 minutes
# - Command: bundle exec rails runner "SendActivityRemindersJob.perform_now"
#
# === Sidekiq Scheduler (Recommended for Production) ===
# 1. Add to Gemfile: gem 'sidekiq-scheduler'
# 2. Create config/sidekiq_scheduler.yml:
#
# send_activity_reminders:
#   cron: '* * * * *'  # Every minute
#   class: SendActivityRemindersJob
#   queue: default
#
