# Custom ActionMailer delivery method for AWS SES using SDK (not SMTP)
# This uses IAM credentials directly without needing SMTP password conversion
# 
# Usage in controller:
#   ActionMailer::Base.add_delivery_method(:aws_ses, AwsSesDelivery)
#   ActionMailer::Base.delivery_method = :aws_ses
#   ActionMailer::Base.aws_ses_settings = {
#     access_key_id: 'AKIAXXXXXXXX',
#     secret_access_key: 'xxxxx',
#     region: 'us-west-2'
#   }

require 'aws-sdk-ses'

class AwsSesDelivery
  attr_accessor :settings

  # The SES MessageId from the most recent deliver! on this instance.
  #
  # Mail::Message#deliver_now returns the mail object, whose #message_id is the RFC 5322
  # Message-ID header, NOT the id SES assigns. SES bounce, complaint and delivery
  # notifications report the SES id, so anything that wants to correlate an event back to
  # a Communication has to read it from here. Callers get at it via
  # mail.delivery_method.ses_message_id after delivering.
  attr_reader :ses_message_id

  def initialize(settings)
    @settings = settings
  end

  def deliver!(mail)
    # Attach the configuration set that publishes bounce/complaint/delivery events to SNS.
    # SESv1 send_raw_email takes this as a header rather than an API parameter, which is
    # why it is set on the message instead of in the request below.
    if configuration_set.present? && mail['X-SES-CONFIGURATION-SET'].nil?
      mail.header['X-SES-CONFIGURATION-SET'] = configuration_set
    end

    send_with_ses(mail)
  rescue Aws::SES::Errors::ServiceError => e
    # SES rejects the whole message when the named configuration set does not exist. Since
    # this setting is an environment variable, a typo or a set that was never created would
    # otherwise take down ALL outbound mail, including password resets and MFA codes, not
    # just the campaign traffic it was added for.
    #
    # Retry once without it: losing delivery events is a reporting gap, losing transactional
    # mail is an outage. The failure is logged loudly so the misconfiguration still gets fixed.
    if configuration_set_missing?(e) && mail['X-SES-CONFIGURATION-SET'].present?
      Rails.logger.error(
        "[AwsSesDelivery] SES configuration set #{configuration_set.inspect} does not exist. " \
        'Sending without it; bounce and delivery events will NOT be recorded until it is created.'
      )
      mail.header['X-SES-CONFIGURATION-SET'] = nil
      return send_with_ses(mail)
    end

    raise
  end

  private

  def send_with_ses(mail)
    # Build the raw email message
    raw_message = {
      data: mail.to_s
    }

    # Create SES client with IAM credentials
    ses_client = Aws::SES::Client.new(
      access_key_id: settings[:access_key_id],
      secret_access_key: settings[:secret_access_key],
      region: settings[:region]
    )

    # Send via SES API
    response = ses_client.send_raw_email({
      raw_message: raw_message,
      source: mail.from.first,
      destinations: mail.to + (mail.cc || []) + (mail.bcc || [])
    })

    @ses_message_id = response.message_id

    # Log success
    Rails.logger.info("[AwsSesDelivery] Email sent via AWS SES API: MessageId=#{response.message_id}")

    response
  rescue Aws::SES::Errors::ServiceError => e
    Rails.logger.error("[AwsSesDelivery] AWS SES API Error: #{e.message}")
    Rails.logger.error("[AwsSesDelivery] Error Code: #{e.code}")
    Rails.logger.error("[AwsSesDelivery] Sender: #{mail.from.first}")
    raise
  rescue StandardError => e
    Rails.logger.error("[AwsSesDelivery] Unexpected error: #{e.message}")
    Rails.logger.error(e.backtrace.first(5).join("\n"))
    raise
  end

  # Matched on code and message rather than a rescue of a named error class: SESv1 reports
  # this as a generic ServiceError in some SDK versions, so keying on the class alone would
  # miss it and let the outage through.
  def configuration_set_missing?(error)
    "#{error.code} #{error.message}".match?(/ConfigurationSetDoesNotExist|Configuration set .* does not exist/i)
  end

  # Ses::ConfigurationSet is the single resolver for this name, and it accepts both variable
  # spellings that have been documented over time. Guarded with defined? because this file
  # is required directly rather than autoloaded, so it has to stay usable if the app's
  # constants are not loaded.
  def configuration_set
    return settings[:configuration_set] if settings[:configuration_set].present?
    return Ses::ConfigurationSet.current if defined?(Ses::ConfigurationSet)

    ENV['SES_CONFIGURATION_SET'].presence || ENV['AWS_SES_CONFIGURATION_SET'].presence
  end
end
