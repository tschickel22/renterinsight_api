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
        
        # For now, fall back to SMTP delivery
        # Future implementation: Use AWS SDK directly for better SES integration
        SmtpProvider.new(company: company).send_message(
          to: to,
          from: "#{from_name} <#{from_address}>",
          subject: subject,
          body: body,
          cc: cc,
          bcc: bcc,
          reply_to: reply_to,
          attachments: attachments,
          **options
        )
      end
    end
  end
end
