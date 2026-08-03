# frozen_string_literal: true

module Webhooks
  # Receives SES bounce / complaint / delivery notifications published to SNS by the
  # configuration set attached to outbound mail.
  #
  # Endpoint is public (SNS cannot authenticate), so every message is signature-verified
  # against Amazon's signing certificate before anything is acted on. Without that, an
  # unauthenticated caller could post a forged Bounce and suppress a real customer, or post
  # a SubscriptionConfirmation pointing at a URL of their choosing and make our server
  # fetch it.
  class SesEventsController < ActionController::Base
    include SnsMessageVerification

    skip_before_action :verify_authenticity_token

    # POST /webhooks/ses/events
    def receive
      message = JSON.parse(request.body.read)

      unless sns_message_authentic?(message)
        Rails.logger.warn('[Webhooks::Ses] rejected message with invalid SNS signature')
        return render json: { error: 'Invalid signature' }, status: :forbidden
      end

      case message['Type']
      when 'SubscriptionConfirmation'
        confirm_sns_subscription(message, log_tag: '[Webhooks::Ses]')
        render json: { success: true, message: 'Subscription confirmed' }
      when 'UnsubscribeConfirmation'
        Rails.logger.warn("[Webhooks::Ses] unsubscribed from topic #{message['TopicArn']}")
        render json: { success: true }
      when 'Notification'
        result = Ses::EventProcessor.process(message['Message'])
        Rails.logger.info("[Webhooks::Ses] #{result.event_type} handled=#{result.handled} send=#{result.send_id}")
        render json: { success: true, handled: result.handled }
      else
        Rails.logger.warn("[Webhooks::Ses] unknown SNS message type #{message['Type']}")
        render json: { success: true }
      end
    rescue JSON::ParserError => e
      Rails.logger.error("[Webhooks::Ses] JSON parse error: #{e.message}")
      render json: { error: 'Invalid JSON' }, status: :bad_request
    rescue => e
      Rails.logger.error("[Webhooks::Ses] #{e.class}: #{e.message}")
      # 200 on purpose: SNS retries non-2xx, and a bug in our handler should not turn into
      # a redelivery storm. The error is logged for us, not for Amazon.
      render json: { success: false }, status: :ok
    end

  end
end
