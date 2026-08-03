# frozen_string_literal: true

require_relative '../../../../lib/aws_ses_delivery'

module Providers
  module Email
    class AwsSesProvider < BaseProvider
      def send_message(to:, from: nil, subject:, body:, cc: nil, bcc: nil, reply_to: nil, attachments: [], inline_images: [], content_type: 'text/html', **options)
        validate_config!

        # Use from parameter or fall back to config
        from_address = from || config[:from_email]
        from_name = config[:from_name] || 'Platform DMS'

        Rails.logger.info "📧 Sending email via AWS SES to #{to} from #{from_address}"
        Rails.logger.info "📧 Reply-To: #{reply_to}" if reply_to.present?

        # Build the mail message
        mail = CommunicationMailer.send_communication(
          to: to,
          from_email: from_address,
          from_name: from_name,
          subject: subject,
          body: body,
          cc: cc,
          bcc: bcc,
          reply_to: reply_to,
          file_attachments: attachments,
          inline_images: inline_images,
          content_type: content_type
        )
        
        # CRITICAL: Set delivery method PER-MESSAGE (thread-safe)
        # Do NOT mutate global ActionMailer::Base settings
        aws_config = build_aws_config
        mail.delivery_method(AwsSesDelivery, aws_config)
        Rails.logger.info "📧 Per-message AWS SES configured: region=#{aws_config[:region]}, key=#{aws_config[:access_key_id]&.first(8)}..."
        
        mail.deliver_now

        # Read the SES MessageId off the delivery method, not off the returned mail object.
        # mail.message_id is the RFC 5322 Message-ID header; SES bounce, complaint and
        # delivery notifications key on the id SES assigns, so storing the header here left
        # every inbound event unmatchable.
        ses_message_id = mail.delivery_method.try(:ses_message_id)

        Rails.logger.info "✅ AWS SES email sent successfully: MessageId=#{ses_message_id}"

        {
          success: true,
          external_id: ses_message_id || mail.message_id,
          provider: 'aws_ses'
        }
      rescue StandardError => e
        Rails.logger.error "❌ AWS SES delivery failed: #{e.message}"
        Rails.logger.error e.backtrace.first(5).join("\n")
        raise DeliveryError, "AWS SES delivery failed: #{e.message}"
      end
      
      private
      
      def build_aws_config
        {
          access_key_id: config[:aws_access_key_id],
          secret_access_key: config[:aws_secret_access_key],
          region: config[:aws_region] || Ses::Region.current,
          configuration_set: config[:ses_configuration_set].presence || Ses::ConfigurationSet.current
        }
      end
    end
  end
end
