# Email sync scheduler - runs every 10 minutes
# Syncs sent emails from Gmail/Outlook IMAP for all users with credentials configured

# Email sync scheduler - ONLY runs in development or when explicitly enabled
# Production should use Render Cron Jobs instead of in-process threads
# In-process threads accumulate memory and contributed to 512MB OOM crashes
if Rails.env.development? || ENV['ENABLE_EMAIL_SYNC_SCHEDULER'] == 'true'
  Rails.application.config.after_initialize do
    ActiveSupport.on_load(:active_record) do
      if defined?(Rails::Server) || defined?(Puma::Server)
        Thread.new do
          sleep 30
          loop do
            begin
              SyncAllUsersSentEmailsJob.perform_now
              sleep 600
              Rails.logger.info "[EmailSync] Scheduled sync completed at #{Time.current}"
            rescue => e
              Rails.logger.error "[EmailSync] Scheduler error: #{e.message}"
            end
          end
        end
      end
    end
  end
else
  Rails.logger.info "[EmailSync] In-process scheduler disabled. Use Render Cron Jobs for production."
end

# PRODUCTION SETUP:
# Add a Render Cron Job:
#   Schedule: */10 * * * * (every 10 minutes)
#   Command: bundle exec rails runner "SyncAllUsersSentEmailsJob.perform_now"
