# frozen_string_literal: true

class WebhookService
  EVENTS = %w[
    contact.created contact.updated contact.deleted
    lead.created lead.updated lead.deleted lead.converted
    account.created account.updated account.deleted
    deal.created deal.updated deal.deleted deal.won deal.lost
    vehicle.created vehicle.updated vehicle.deleted vehicle.sold vehicle.archived
    invoice.created invoice.updated invoice.deleted invoice.paid invoice.overdue
    service_ticket.created service_ticket.updated service_ticket.deleted
    quote.created quote.updated quote.deleted quote.approved quote.rejected
    location.created location.updated location.deleted
    payment.created payment.updated payment.deleted payment.received payment.refunded
    loan.created loan.updated loan.deleted
    inventory.increase
    inventory.decrease
    parts.added
    parts.edited
    parts.removed
    parts.low_stock
    workflow_rule.activated workflow_rule.paused
    workflow_run.started workflow_run.completed workflow_run.failed
    social_post.created social_post.updated social_post.deleted social_post.published
    campaign.started campaign.paused campaign.resumed campaign.completed campaign.archived
    campaign.enrollment_created campaign.enrollment_completed campaign.goal_met
    campaign.unsubscribed campaign.bounced campaign.complained
    campaign.compliance_acknowledged
  ].freeze

  # Fire a webhook event for a company
  #
  # @param company_id [Integer] The company that owns the data
  # @param event [String] Event name, e.g. "contact.created"
  # @param payload [Hash] The data to send
  # @param location_id [Integer, nil] Optional location context for filtering
  def self.fire(company_id:, event:, payload:, location_id: nil)
    return unless EVENTS.include?(event.to_s)

    # Find matching endpoints:
    # 1. Platform-level endpoints (company_id IS NULL) — always receive all events
    # 2. Company-scoped endpoints matching this company
    endpoints = WebhookEndpoint
      .where(company_id: [nil, company_id])
      .active
      .for_event(event)

    endpoints.find_each do |endpoint|
      # Skip if endpoint has a location filter that doesn't match
      next unless endpoint.matches_location?(location_id)

      delivery = WebhookDelivery.create!(
        webhook_endpoint: endpoint,
        event: event,
        payload: build_envelope(event, payload, company_id: company_id, location_id: location_id)
      )

      WebhookDeliveryJob.perform_later(delivery.id)
    end
  rescue => e
    Rails.logger.error "[WebhookService] Failed to fire #{event} for company #{company_id}: #{e.message}"
  end

  # Build a standardized event envelope
  def self.build_envelope(event, payload, company_id: nil, location_id: nil)
    envelope = {
      id: SecureRandom.uuid,
      event: event,
      created_at: Time.current.iso8601,
      data: payload
    }

    # Include scope context so consumers know where the event came from
    envelope[:company_id] = company_id if company_id.present?
    envelope[:location_id] = location_id if location_id.present?

    envelope
  end
end
