# frozen_string_literal: true

module Campaigns
  # Tells the workflow engine that someone engaged with a campaign.
  #
  # Opens, clicks, replies, bounces and unsubscribes were written to
  # campaign_sends and never reached WorkflowEngine, so no automation could
  # react to them. "They clicked a home, call them" and "they never opened it,
  # send a text" could not be built.
  #
  # Events fire on the recipient (Lead, Contact or Account). Opens, clicks and
  # replies fire once per email sent, because a rule has no guard against
  # running twice and a prospect who opens five times must not start five
  # follow-ups. Every event carries campaign_id, so a rule can be scoped to one
  # campaign with a trigger.campaign_id condition.
  class WorkflowBridge
    EVENT_TYPES = {
      opened: 'campaign.opened',
      clicked: 'campaign.clicked',
      replied: 'campaign.replied',
      bounced: 'campaign.bounced',
      unsubscribed: 'campaign.unsubscribed'
    }.freeze

    RECIPIENT_TYPES = %w[Lead Contact Account].freeze

    def self.emit(kind, send: nil, enrollment: nil, **extra)
      enrollment ||= send&.campaign_enrollment
      return unless enrollment
      # A test send goes to the admin who pressed the button, not a prospect.
      return if enrollment.metadata.is_a?(Hash) && enrollment.metadata['test_send'].to_s == 'true'
      return unless RECIPIENT_TYPES.include?(enrollment.recipient_type)

      recipient = enrollment.recipient
      return unless recipient

      campaign = enrollment.campaign
      payload = {
        campaign_id: campaign&.id,
        campaign_name: campaign&.name,
        campaign_enrollment_id: enrollment.id,
        campaign_send_id: send&.id,
        campaign_step_id: send&.campaign_step_id,
        channel: campaign&.channel
      }.merge(extra).compact.deep_stringify_keys

      WorkflowEngine.emit(EVENT_TYPES.fetch(kind), recipient, payload)
    rescue StandardError => e
      # Tracking must never break a redirect, a pixel, or a stored reply.
      Rails.logger.error "[Campaigns::WorkflowBridge] #{kind} failed: #{e.class}: #{e.message}"
      nil
    end
  end
end
