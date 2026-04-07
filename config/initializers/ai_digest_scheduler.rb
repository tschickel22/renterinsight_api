# Schedules the weekly AI digest to run every Monday at 7:30 AM local time.
# Production: set up a Render Cron Job instead of this thread.

if Rails.env.development? || ENV['ENABLE_AI_DIGEST_SCHEDULER'] == 'true'
  Rails.application.config.after_initialize do
    Thread.new do
      loop do
        begin
          now = Time.current
          if now.monday? && now.hour == 7 && now.min.between?(30, 34)
            Rails.logger.info "[AiDigestScheduler] Firing weekly digest"
            SendAiDigestJob.perform_now
            sleep 300
          end
        rescue => e
          Rails.logger.error "[AiDigestScheduler] #{e.message}"
        end
        sleep 60
      end
    end
  end
end

# PRODUCTION SETUP (Render):
# Add a Cron Job in Render dashboard:
#   Schedule: 30 7 * * 1   (7:30 AM every Monday)
#   Command:  bundle exec rails runner "SendAiDigestJob.perform_now"
