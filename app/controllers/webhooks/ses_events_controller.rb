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
    skip_before_action :verify_authenticity_token

    # POST /webhooks/ses/events
    def receive
      message = JSON.parse(request.body.read)

      unless verified?(message)
        Rails.logger.warn('[Webhooks::Ses] rejected message with invalid SNS signature')
        return render json: { error: 'Invalid signature' }, status: :forbidden
      end

      case message['Type']
      when 'SubscriptionConfirmation'
        confirm_subscription(message)
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

    private

    def verified?(message)
      Aws::SNS::MessageVerifier.new.authentic?(message.to_json)
    rescue => e
      Rails.logger.error("[Webhooks::Ses] signature verification failed: #{e.message}")
      false
    end

    def confirm_subscription(message)
      url = message['SubscribeURL'].to_s
      uri = URI.parse(url)

      # Signature verification already proves Amazon sent this, but pin the host anyway so
      # a confirmed-authentic message can never point us at an arbitrary origin.
      unless uri.scheme == 'https' && uri.host.to_s.end_with?('.amazonaws.com')
        Rails.logger.error("[Webhooks::Ses] refusing to confirm subscription at #{uri.host}")
        return
      end

      response = Net::HTTP.get_response(uri)
      if response.is_a?(Net::HTTPSuccess)
        Rails.logger.info("[Webhooks::Ses] confirmed subscription to #{message['TopicArn']}")
      else
        Rails.logger.error("[Webhooks::Ses] subscription confirmation returned #{response.code}")
      end
    end
  end
end
