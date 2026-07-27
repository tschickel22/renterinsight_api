# frozen_string_literal: true

# Reads each active sending mailbox's INBOX for bounce (NDR) and out-of-office
# replies and feeds them to Campaigns::BounceHandler. Campaigns send from
# owners' Gmail/Outlook accounts, so these signals land in the sender's mailbox
# and never reach the reply+campaign-<id>@ inbound webhook. Runs every 10 min,
# alongside SyncAllUsersSentEmailsJob (same connections, same Mail.Read/IMAP scope).
class HarvestCampaignBouncesJob < ApplicationJob
  queue_as :default

  LOOKBACK_MINUTES = 30 # exceeds the 10-min cadence so slow NDRs aren't missed

  def perform
    connections = UserEmailConnection.where(provider: %w[oauth_gmail oauth_outlook smtp], is_active: true)
    totals = { scanned: 0, handled: 0, bounces: 0, auto_replies: 0 }

    connections.find_each do |connection|
      res = Campaigns::InboundBounceHarvester.harvest_connection(connection, minutes_back: LOOKBACK_MINUTES)
      totals[:scanned] += res.scanned.to_i
      totals[:handled] += res.handled.to_i
      totals[:bounces] += res.bounces.to_i
      totals[:auto_replies] += res.auto_replies.to_i

      if res.handled.to_i.positive?
        Rails.logger.info "[BounceHarvest] #{connection.email_address}: #{res.bounces} bounce(s), #{res.auto_replies} auto-reply(ies) from #{res.scanned} scanned"
      elsif res.error.present?
        Rails.logger.warn "[BounceHarvest] #{connection.email_address}: #{res.error}"
      end
    rescue => e
      Rails.logger.error "[BounceHarvest] connection #{connection.id} failed: #{e.message}"
    end

    Rails.logger.info "[BounceHarvest] done: scanned=#{totals[:scanned]} handled=#{totals[:handled]} bounces=#{totals[:bounces]} auto_replies=#{totals[:auto_replies]}"
  end
end
