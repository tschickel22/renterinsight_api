# frozen_string_literal: true

# Job to sync sent emails for all users with email credentials configured
# Looks back 30 minutes to capture emails sent from Gmail/Outlook
class SyncAllUsersSentEmailsJob < ApplicationJob
  queue_as :default
  
  def perform
    users = User.where.not(email_username: nil).where.not(smtp_server: nil)
    
    if users.none?
      Rails.logger.info "[EmailSync] No users with email credentials configured"
      return
    end
    
    Rails.logger.info "[EmailSync] Syncing sent emails for #{users.count} users (30 min window)..."
    
    synced_total = 0
    users.each do |user|
      begin
        result = ImapSentEmailService.sync_sent_emails(user, 30)
        
        if result[:success]
          synced_total += result[:synced_count]
          if result[:synced_count] > 0
            Rails.logger.info "[EmailSync] #{user.email_username}: synced #{result[:synced_count]}/#{result[:total_emails]}"
          end
        else
          Rails.logger.error "[EmailSync] #{user.email_username}: #{result[:error]}"
        end
      rescue => e
        Rails.logger.error "[EmailSync] #{user.email_username}: #{e.message}"
      end
    end
    
    Rails.logger.info "[EmailSync] Completed: #{synced_total} total emails synced"
  end
end
