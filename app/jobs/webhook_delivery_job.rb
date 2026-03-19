# frozen_string_literal: true

class WebhookDeliveryJob < ApplicationJob
  queue_as :webhooks

  retry_on StandardError, wait: :polynomially_longer, attempts: 5
  discard_on ActiveRecord::RecordNotFound
  discard_on ActiveRecord::RecordInvalid  # Don't retry validation errors (e.g. invalid events on endpoint)

  def perform(delivery_id)
    delivery = WebhookDelivery.find(delivery_id)
    endpoint = delivery.webhook_endpoint

    return if endpoint.inactive?
    return if delivery.max_attempts_reached?

    payload_json = delivery.payload.to_json
    signature = endpoint.sign_payload(delivery.payload)

    response = make_request(
      url: endpoint.url,
      body: payload_json,
      signature: signature,
      delivery_id: delivery.id
    )

    delivery.record_response!(code: response[:code], body: response[:body])

    if delivery.successful?
      endpoint.record_success!
    else
      endpoint.record_failure!
      raise StandardError, "Webhook delivery failed: HTTP #{response[:code]}" unless delivery.max_attempts_reached?
    end
  end

  private

  def make_request(url:, body:, signature:, delivery_id:)
    uri = URI.parse(url)
    http = Net::HTTP.new(uri.host, uri.port)
    http.use_ssl = uri.scheme == "https"
    http.open_timeout = 10
    http.read_timeout = 30

    request = Net::HTTP::Post.new(uri.path.presence || "/")
    request["Content-Type"] = "application/json"
    request["User-Agent"] = "RenterInsight-Webhooks/1.0"
    request["X-Webhook-Signature"] = signature
    request["X-Webhook-Id"] = delivery_id.to_s
    request.body = body

    response = http.request(request)

    { code: response.code.to_i, body: response.body }
  rescue Net::OpenTimeout, Net::ReadTimeout => e
    { code: 0, body: "Timeout: #{e.message}" }
  rescue SocketError, Errno::ECONNREFUSED, Errno::EHOSTUNREACH => e
    { code: 0, body: "Connection error: #{e.message}" }
  rescue => e
    { code: 0, body: "Error: #{e.class} - #{e.message}" }
  end
end
