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

  private

  def configuration_set
    settings[:configuration_set].presence || ENV['SES_CONFIGURATION_SET'].presence
  end
end
