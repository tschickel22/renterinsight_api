# frozen_string_literal: true

class WebhookService
  EVENTS = %w[
    contact.created contact.updated contact.deleted
    lead.created lead.updated lead.deleted
    account.created account.updated account.deleted
    deal.created deal.updated deal.deleted
    vehicle.created vehicle.updated vehicle.deleted
    invoice.created invoice.updated invoice.deleted
    service_ticket.created service_ticket.updated service_ticket.deleted
    quote.created quote.updated quote.deleted
    location.created location.updated location.deleted
    payment.created payment.updated payment.deleted
    loan.created loan.updated loan.deleted
  ].freeze

  # Fire a webhook event for a company
  #
  # @param company_id [Integer] The company that owns the data
  # @param event [String] Event name, e.g. "contact.created"
  # @param payload [Hash] The data to send
  def self.fire(company_id:, event:, payload:)
    return unless EVENTS.include?(event.to_s)

    endpoints = WebhookEndpoint
      .where(company_id: company_id)
      .active
      .for_event(event)

    endpoints.find_each do |endpoint|
      delivery = WebhookDelivery.create!(
        webhook_endpoint: endpoint,
        event: event,
        payload: build_envelope(event, payload)
      )

      WebhookDeliveryJob.perform_later(delivery.id)
    end
  rescue => e
    Rails.logger.error "[WebhookService] Failed to fire #{event} for company #{company_id}: #{e.message}"
  end

  # Build a standardized event envelope
  def self.build_envelope(event, payload)
    {
      id: SecureRandom.uuid,
      event: event,
      created_at: Time.current.iso8601,
      data: payload
    }
  end
end
