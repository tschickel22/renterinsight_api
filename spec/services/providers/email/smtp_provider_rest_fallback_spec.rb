# frozen_string_literal: true

require 'rails_helper'

# Regression: a send-only Gmail grant reached SmtpProvider and Gmail's SMTP
# rejected the XOAUTH2 token with {"status":"400","scope":"https://mail.google.com/"}.
# The controllers had a REST branch; this path did not, so workflows, nurture,
# agreements, and intake all failed to send.
RSpec.describe Providers::Email::SmtpProvider do
  let(:provider) { described_class.allocate }

  def configure(overrides)
    base = {
      from_email: 'rep@example.com',
      from_name: 'Rep',
      smtp_host: 'smtp.gmail.com',
      smtp_port: 587,
      smtp_username: 'rep@example.com',
      smtp_password: 'tok',
      smtp_authentication: 'xoauth2'
    }.merge(overrides)
    provider.instance_variable_set(:@config, base)
  end

  let(:send_args) do
    { to: 'buyer@example.com', subject: 'Hello', body: '<p>Hi</p>' }
  end

  context 'when the grant is too narrow for SMTP' do
    before { configure(requires_rest_send: true, oauth_access_token: 'tok', oauth_refresh_token: 'rtok') }

    it 'delivers over the Gmail REST API and never opens an SMTP connection' do
      allow(Providers::Email::GmailApiProvider).to receive(:deliver_raw)
        .and_return({ success: true, message_id: 'ours@srv.mail', gmail_id: 'g1' })

      result = provider.send_message(**send_args)

      expect(Providers::Email::GmailApiProvider).to have_received(:deliver_raw)
      expect(result[:success]).to be true
      expect(result[:provider]).to eq('gmail_api')
      expect(result[:external_id]).to eq('ours@srv.mail')
    end

    it 'passes a real RFC 2822 message carrying the recipient and subject' do
      captured = nil
      allow(Providers::Email::GmailApiProvider).to receive(:deliver_raw) do |args|
        captured = args[:raw_message]
        { success: true, message_id: args[:message_id] }
      end

      provider.send_message(**send_args)

      expect(captured).to include('buyer@example.com')
      expect(captured).to include('Hello')
      expect(captured).to match(/Message-ID:/i)
    end

    # CommunicationService's rescue is what flags the connection for re-auth,
    # so this path has to raise rather than return a failure hash.
    it 'raises DeliveryError when the API rejects the send' do
      allow(Providers::Email::GmailApiProvider).to receive(:deliver_raw)
        .and_return({ success: false, error: 'Request had insufficient authentication scopes.' })

      expect { provider.send_message(**send_args) }
        .to raise_error(Providers::Email::BaseProvider::DeliveryError, /insufficient authentication scopes/)
    end
  end

  context 'when the grant still covers SMTP' do
    before { configure(requires_rest_send: false, oauth_access_token: 'tok') }

    it 'does not touch the Gmail API' do
      allow(Providers::Email::GmailApiProvider).to receive(:deliver_raw)
      # Stub the delivery itself so the test never opens a socket to Gmail.
      allow_any_instance_of(ActionMailer::MessageDelivery)
        .to receive(:deliver_now).and_return(double(message_id: 'smtp@srv.mail'))

      result = provider.send_message(**send_args)

      expect(result[:provider]).to eq('smtp')

      expect(Providers::Email::GmailApiProvider).not_to have_received(:deliver_raw)
    end
  end
end
