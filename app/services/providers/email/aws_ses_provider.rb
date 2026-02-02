# frozen_string_literal: true

module Providers
  module Email
    class AwsSesProvider < BaseProvider
      def send_message(to:, from: nil, subject:, body:, cc: nil, bcc: nil, reply_to: nil, attachments: [], **options)
        validate_config!
        
        # Use from parameter or fall back to config
        from_address = from || config[:from_email]
        from_name = config[:from_name] || 'Platform DMS'
        
        Rails.logger.info "📧 Sending email via AWS SES to #{to} from #{from_address}"
        Rails.logger.info "📧 Reply-To: #{reply_to}" if reply_to.present?
        
        # Configure ActionMailer to use AWS SES SDK
        configure_aws_ses_sdk
        
        # Use CommunicationMailer.send_communication (same as Platform test email)
        mail = CommunicationMailer.send_communication(
          to: to,
          from_email: from_address,
          from_name: from_name,
          subject: subject,
          body: body,
          cc: cc,
          bcc: bcc,
          reply_to: reply_to,
          file_attachments: attachments
        )
        
        result = mail.deliver_now
        
        Rails.logger.info "✅ AWS SES email sent successfully: #{result.message_id}"
        
        {
          success: true,
          external_id: result.message_id,
          provider: 'aws_ses'
        }
      rescue StandardError => e
        Rails.logger.error "❌ AWS SES delivery failed: #{e.message}"
        Rails.logger.error e.backtrace.first(5).join("\n")
        raise DeliveryError, "AWS SES delivery failed: #{e.message}"
      end
      
      private
      
      def configure_aws_ses_sdk
      # Require the custom delivery method (same as Platform Settings)
      require_relative '../../../../lib/aws_ses_delivery'

      # Register the custom AWS SES delivery method
      ActionMailer::Base.add_delivery_method(:aws_ses_sdk, AwsSesDelivery)

        # Get AWS credentials from config
      aws_config = {
        access_key_id: config[:aws_access_key_id],
        secret_access_key: config[:aws_secret_access_key],
        region: config[:aws_region] || 'us-west-2'
        }

        # Configure ActionMailer to use AWS SES SDK (not SMTP)
      ActionMailer::Base.delivery_method = :aws_ses_sdk  # Correct name!
      ActionMailer::Base.aws_ses_sdk_settings = aws_config
        ActionMailer::Base.perform_deliveries = true
        ActionMailer::Base.raise_delivery_errors = true

        Rails.logger.info "📧 ActionMailer AWS SES SDK configured: region=#{aws_config[:region]}, key=#{aws_config[:access_key_id]}"
      rescue StandardError => e
        Rails.logger.error "❌ Failed to configure AWS SES: #{e.message}"
        raise
      end
    end
  end
end
