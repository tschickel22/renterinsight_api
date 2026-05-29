module Campaigns
  class ReplyHandler
    OOO_HEADER_PATTERNS = [
      /auto-?submitted:\s*auto-replied/i,
      /x-autoreply/i, /x-autorespond/i, /precedence:\s*auto/i
    ].freeze
    OOO_SUBJECT_PATTERNS = [
      /out of office/i, /automatic reply/i, /auto[- ]reply/i, /vacation/i,
      /away from (the )?office/i
    ].freeze

    Result = Struct.new(:handled, :enrollment_id, :send_id, :is_ooo, keyword_init: true)

    # token format: "campaign-<send_id>"
    def self.process(token:, parsed_email:)
      return Result.new(handled: false) unless token.to_s.start_with?('campaign-')
      send_id = token.split('-', 2).last.to_i
      send = CampaignSend.find_by(id: send_id)
      return Result.new(handled: false) unless send

      enrollment = send.campaign_enrollment
      campaign = send.campaign

      ooo = ooo?(parsed_email)
      inbound = nil

      ActiveRecord::Base.transaction do
        send.update_columns(replied_at: send.replied_at || Time.current) unless ooo

        inbound = Communication.create!(
          communicable: enrollment.recipient,
          company_id: send.company_id,
          channel: 'email', direction: 'inbound',
          status: 'delivered',
          from_address: parsed_email[:from], to_address: parsed_email[:to],
          subject: parsed_email[:subject], body: parsed_email[:body_text].to_s,
          sent_at: parsed_email[:timestamp] || Time.current,
          metadata: {
            'campaign_id' => campaign.id,
            'campaign_send_id' => send.id,
            'is_ooo' => ooo
          }
        )

        next if ooo

        goals = Array(campaign.goal_config['additional_goals']) + [campaign.goal_config['primary_goal']]
        if goals.compact.include?('replied')
          enrollment.update!(status: 'goal_met', goal_met_at: Time.current, goal_met_reason: 'replied')
          CampaignEvent.create!(
            company_id: send.company_id, campaign_id: campaign.id,
            campaign_enrollment_id: enrollment.id, campaign_send_id: send.id,
            event_type: 'goal_met', occurred_at: Time.current, payload: { reason: 'replied' }
          )
          if defined?(WebhookService)
            WebhookService.fire(
              company_id: send.company_id, event: 'campaign.goal_met',
              payload: { campaign_id: campaign.id, enrollment_id: enrollment.id, goal: 'replied' }
            )
          end
        else
          enrollment.update!(status: 'paused')
          CampaignEvent.create!(
            company_id: send.company_id, campaign_id: campaign.id,
            campaign_enrollment_id: enrollment.id, campaign_send_id: send.id,
            event_type: 'paused', occurred_at: Time.current, payload: { reason: 'replied' }
          )
        end
      end

      # Notify the user who sent the campaign email (falls back to the lead's owner).
      # Skipped for auto-replies. Outside the transaction so a notification failure can't
      # roll back the captured reply; the notifier also rescues internally.
      unless ooo
        InboundEmail::ReplyNotifier.notify(
          entity: enrollment.recipient,
          communication: inbound,
          outbound_communication: send.communication
        )
      end

      Result.new(handled: true, enrollment_id: enrollment.id, send_id: send.id, is_ooo: ooo)
    end

    def self.ooo?(parsed_email)
      headers = parsed_email[:headers].to_s
      return true if OOO_HEADER_PATTERNS.any? { |p| headers.match?(p) }
      OOO_SUBJECT_PATTERNS.any? { |p| parsed_email[:subject].to_s.match?(p) }
    end
  end
end
