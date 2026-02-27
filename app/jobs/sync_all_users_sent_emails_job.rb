# frozen_string_literal: true

# Job to sync sent emails for all users with email credentials configured
# Looks back 30 minutes to capture emails sent from Gmail/Outlook
# Supports both legacy SMTP credentials (User fields) and OAuth connections (UserEmailConnection)
class SyncAllUsersSentEmailsJob < ApplicationJob
  queue_as :default

  def perform
    synced_total = 0

    # 1. Legacy SMTP users (email_username + smtp_server on User model)
    smtp_users = User.where.not(email_username: nil).where.not(smtp_server: nil)
    if smtp_users.any?
      Rails.logger.info "[EmailSync] Syncing #{smtp_users.count} SMTP users (30 min window)..."
      smtp_users.each do |user|
        begin
          result = ImapSentEmailService.sync_sent_emails(user, 30)
          if result[:success]
            synced_total += result[:synced_count]
            Rails.logger.info "[EmailSync] SMTP #{user.email_username}: synced #{result[:synced_count]}" if result[:synced_count] > 0
          else
            Rails.logger.error "[EmailSync] SMTP #{user.email_username}: #{result[:error]}"
          end
        rescue => e
          Rails.logger.error "[EmailSync] SMTP #{user.email_username}: #{e.message}"
        end
      end
    end

    # 2. OAuth connections (UserEmailConnection with oauth_gmail or oauth_outlook)
    oauth_connections = UserEmailConnection.where(provider: %w[oauth_gmail oauth_outlook], is_active: true)
    if oauth_connections.any?
      Rails.logger.info "[EmailSync] Syncing #{oauth_connections.count} OAuth connections (30 min window)..."
      oauth_connections.each do |connection|
        begin
          result = ImapSentEmailService.sync_via_connection(connection, 30)
          if result[:success]
            synced_total += result[:synced_count]
            Rails.logger.info "[EmailSync] OAuth #{connection.email_address}: synced #{result[:synced_count]}" if result[:synced_count] > 0
          else
            Rails.logger.error "[EmailSync] OAuth #{connection.email_address}: #{result[:error]}"
          end
        rescue => e
          Rails.logger.error "[EmailSync] OAuth #{connection.email_address}: #{e.message}"
        end
      end
    end

    Rails.logger.info "[EmailSync] Completed: #{synced_total} total emails synced"
  end
end
