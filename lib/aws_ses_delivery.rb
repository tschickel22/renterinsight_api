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
  
  def initialize(settings)
    @settings = settings
  end
  
  def deliver!(mail)
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
end
