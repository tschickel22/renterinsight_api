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
    all_oauth = UserEmailConnection.where(provider: %w[oauth_gmail oauth_outlook], is_active: true)

    # A connection whose grant the provider has permanently rejected cannot be
    # repaired by polling it again: only the user re-running OAuth fixes it, and
    # they were notified when it was flagged. Retrying regardless is what turned
    # one stale Gmail mailbox into hundreds of rejected token requests a day
    # against our OAuth client, every day, forever.
    all_oauth, awaiting_reconnect = all_oauth.to_a.partition { |c| !c.needs_reauth? }
    if awaiting_reconnect.any?
      Rails.logger.info "[EmailSync] Skipping #{awaiting_reconnect.count} connection(s) awaiting reconnect: #{awaiting_reconnect.map(&:email_address).join(', ')}"
    end

    # A send-only grant (Gmail's gmail.send) can post a message but cannot list
    # one. Attempting anyway fails on auth, and EmailConnectionHealth would read
    # that as a dead token and tell the user to reconnect a mailbox that is
    # sending perfectly well.
    oauth_connections, send_only = all_oauth.partition(&:can_read_mailbox?)
    if send_only.any?
      Rails.logger.info "[EmailSync] Skipping #{send_only.count} send-only connection(s): #{send_only.map(&:email_address).join(', ')}"
    end

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
