# Email sync scheduler - runs every 10 minutes
# Syncs sent emails from Gmail/Outlook IMAP for all users with credentials configured

Rails.application.config.after_initialize do
  # Schedule the job to run every 10 minutes
  ActiveSupport.on_load(:active_record) do
    if defined?(Rails::Server) || defined?(Puma::Server)
      Thread.new do
        # Wait for Rails to fully boot before starting scheduler
        sleep 30
        
        loop do
          begin
            # Run the sync job
            SyncAllUsersSentEmailsJob.perform_now
            
            # Sleep until next run (10 minutes)
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
