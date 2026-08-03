# frozen_string_literal: true

# Shared handling for endpoints that receive Amazon SNS messages.
#
# SNS cannot authenticate itself with a shared secret, so these endpoints are necessarily
# public. That makes signature verification the only thing standing between an anonymous
# HTTP client and whatever the handler does with the payload, which in our case includes
# suppressing customer email addresses and writing Communications against real records.
#
# Every message is verified against Amazon's signing certificate before it is acted on, and
# subscription confirmations additionally pin the SubscribeURL host so a message that is
# authentic but malformed still cannot make the server fetch an arbitrary origin.
module SnsMessageVerification
  extend ActiveSupport::Concern

  # Amazon publishes SNS signing certs under regional amazonaws.com hosts. The SDK checks
  # this too; the explicit check here documents the requirement at the point of use and
  # covers the confirmation fetch, which the SDK never sees.
  AWS_HOST_SUFFIX = '.amazonaws.com'

  private

  def sns_message_authentic?(message)
    Aws::SNS::MessageVerifier.new.authentic?(message.to_json)
  rescue StandardError => e
    Rails.logger.error("[SNS] signature verification failed: #{e.class}: #{e.message}")
    false
  end

  # Confirms a subscription only when the URL is an https AWS host. Signature verification
  # already proves Amazon sent the message, so this is defence in depth rather than the
  # primary control, but it is what turns a hypothetical signature bypass into a dead end
  # instead of server-side request forgery.
  def confirm_sns_subscription(message, log_tag:)
    url = message['SubscribeURL'].to_s
    if url.blank?
      Rails.logger.error("#{log_tag} subscription confirmation had no SubscribeURL")
      return false
    end

    uri = begin
      URI.parse(url)
    rescue URI::InvalidURIError
      nil
    end

    unless uri.is_a?(URI::HTTPS) && uri.host.to_s.end_with?(AWS_HOST_SUFFIX)
      Rails.logger.error("#{log_tag} refusing to confirm subscription at #{uri&.host.inspect}")
      return false
    end

    response = Net::HTTP.get_response(uri)
    if response.is_a?(Net::HTTPSuccess)
      Rails.logger.info("#{log_tag} confirmed subscription to #{message['TopicArn']}")
      true
    else
      Rails.logger.error("#{log_tag} subscription confirmation returned #{response.code}")
      false
    end
  rescue StandardError => e
    Rails.logger.error("#{log_tag} subscription confirmation failed: #{e.message}")
    false
  end
end
