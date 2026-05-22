# frozen_string_literal: true

module Providers
  module Email
    class GmailRelayProvider < BaseProvider
      def send_message(to:, from: nil, subject:, body:, cc: nil, bcc: nil, reply_to: nil, attachments: [], content_type: 'text/html', **options)
        # Gmail Relay uses SMTP, so we can delegate to SmtpProvider
        # with Gmail-specific configuration
        SmtpProvider.new(company: company).send_message(
          to: to,
          from: from,
          subject: subject,
          body: body,
          cc: cc,
          bcc: bcc,
          reply_to: reply_to,
          attachments: attachments,
          content_type: content_type,
          **options
        )
      end
    end
  end
end
