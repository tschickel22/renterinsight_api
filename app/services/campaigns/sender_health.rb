# frozen_string_literal: true

module Campaigns
  # Whether a campaign's sender can send right now, and what to do when it cannot.
  #
  # A broken sender is a problem with the campaign, not with any one recipient.
  # It used to be handled per recipient: every send failed its enrollment with
  # "no_valid_email_connection", the scheduler then found nobody left and marked
  # the campaign completed, and a completed campaign can be neither paused nor
  # edited. Campaign 26 lost 586 recipients that way in September 2026.
  #
  # Now the first send that finds the sender unusable pauses the campaign once,
  # records why on the campaign, and tells the people who can fix it. Every
  # enrollment stays at its step, so resuming picks each one up where it stopped.
  #
  # Scope: campaigns with one fixed sender (User, Location, Company). Owner mode
  # resolves a different mailbox per recipient, and one rep's broken mailbox must
  # not stop everyone else's; a waterfall campaign always has a fallback sender.
  # Both keep their per-recipient handling.
  class SenderHealth
    Problem = Struct.new(:code, :message, :reconnect_path, keyword_init: true) do
      def to_h
        { 'code' => code, 'message' => message, 'reconnect_path' => reconnect_path, 'paused_by' => 'system' }
      end
    end

    REAUTH_MARKER = 'Reauth required:'

    class << self
      # nil when the sender is usable, otherwise a Problem saying what to fix.
      def problem_for(campaign)
        return nil unless applies_to?(campaign)

        connection = campaign.resolve_email_connection_for_step
        return missing_sender_problem(campaign) if connection.nil?
        return reauth_problem(campaign, connection) if needs_reauth?(connection)

        nil
      end

      # A provider error that means the sender itself is broken, not one recipient.
      def sender_error?(message)
        EmailConnectionHealth.actionable_error?(message)
      end

      def problem_from_error(campaign, message)
        Problem.new(
          code: 'sender_rejected',
          message: "The email service rejected this campaign's sender (#{message.to_s.squish.truncate(140)}). " \
                   'Fix or reconnect the sender, then resume the campaign.',
          reconnect_path: reconnect_path_for(campaign)
        )
      end

      # Pauses a running campaign for a sender problem. Returns true only for the
      # call that actually paused it, so a batch of sends reaching the same broken
      # sender notifies once.
      def pause!(campaign, problem)
        now = Time.current
        claimed = Campaign.where(id: campaign.id, status: 'running')
                          .update_all(status: 'paused', pause_reason: problem.to_h, paused_at: now, updated_at: now)
        return false unless claimed == 1

        campaign.reload
        Rails.logger.warn "[Campaigns::SenderHealth] Paused campaign #{campaign.id}: #{problem.code}"
        if defined?(WebhookService)
          WebhookService.fire(company_id: campaign.company_id, event: 'campaign.paused',
                              payload: { campaign_id: campaign.id, reason: problem.code })
        end
        notify(campaign, problem)
        true
      end

      # Called when a mailbox is found to need reconnecting, so campaigns sending
      # through it pause straight away instead of waiting for their next send.
      def pause_campaigns_for_connection!(connection)
        candidates = candidates_for(connection)
        return 0 if candidates.nil?

        candidates.find_each.count do |campaign|
          problem = problem_for(campaign)
          problem && pause!(campaign, problem)
        end
      rescue StandardError => e
        Rails.logger.error "[Campaigns::SenderHealth] pause_campaigns_for_connection! failed: #{e.class}: #{e.message}"
        0
      end

      private

      def applies_to?(campaign)
        return false if campaign.owner_identity? || campaign.email_waterfall?

        channels = campaign.campaign_steps.active.pluck(:channel).compact.uniq
        channels.include?('email') || (channels.empty? && campaign.email_channel?)
      end

      def candidates_for(connection)
        running = Campaign.running.where(email_waterfall: false)
        case connection
        when UserEmailConnection
          running.where(from_identity_type: 'User', from_identity_id: connection.user_id)
        when LocationEmailConnection
          running.where(from_identity_type: 'Location', from_identity_id: connection.location_id)
        when CompanyEmailConnection
          running.where(from_identity_type: 'Company', company_id: connection.company_id)
        end
      end

      # An SES sending identity has no mailbox to go stale; only a mailbox does.
      def needs_reauth?(connection)
        return false unless connection.respond_to?(:last_error_message)
        return connection.needs_reauth? if connection.respond_to?(:needs_reauth?)

        connection.last_error_message.to_s.start_with?(REAUTH_MARKER)
      end

      def missing_sender_problem(campaign)
        if campaign.from_identity_type == 'User' && campaign.identity_user.nil?
          return Problem.new(
            code: 'sender_missing',
            message: 'The person this campaign sends as is no longer available. ' \
                     'Choose a new sender in the campaign settings, then resume.',
            reconnect_path: "/campaigns/#{campaign.id}"
          )
        end

        Problem.new(
          code: 'sender_not_connected',
          message: "#{sender_label(campaign)} has no connected mailbox. Connect one, then resume the campaign.",
          reconnect_path: reconnect_path_for(campaign)
        )
      end

      def reauth_problem(campaign, connection)
        Problem.new(
          code: 'sender_needs_reauth',
          message: "#{connection.email_address} needs to be reconnected. Reconnect it, then resume the campaign.",
          reconnect_path: reconnect_path_for(campaign)
        )
      end

      def reconnect_path_for(campaign)
        campaign.from_identity_type == 'User' ? '/account/settings?tab=email' : '/settings?tab=communications'
      end

      def sender_label(campaign)
        case campaign.from_identity_type
        when 'User'     then campaign.identity_user&.email || 'The sender'
        when 'Location' then Location.find_by(id: campaign.from_identity_id)&.name || 'This location'
        when 'Company'  then campaign.company&.name || 'This company'
        else 'The sender'
        end
      end

      def notify(campaign, problem)
        recipients = [User.find_by(id: campaign.created_by_user_id)]
        recipients << campaign.identity_user if campaign.from_identity_type == 'User'

        recipients.compact.uniq(&:id).each do |user|
          NotificationService.create(
            recipient: user,
            notification_type: :campaign_paused_sender,
            notifiable: campaign,
            message: "\"#{campaign.name}\" is paused. #{problem.message} " \
                     'Everyone in the campaign stays at their current step.',
            action_url: "/campaigns/#{campaign.id}",
            action_text: 'Open campaign',
            company_id: campaign.company_id,
            deliver_now: true
          )
        end
      rescue StandardError => e
        Rails.logger.error "[Campaigns::SenderHealth] notify failed for campaign #{campaign.id}: #{e.class}: #{e.message}"
      end
    end
  end
end
