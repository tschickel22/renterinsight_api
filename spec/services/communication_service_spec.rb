require 'rails_helper'

# CommunicationService against its current contract: sends return a result
# hash ({ success:, communication:, ... }), a provider failure comes back as
# success: false with the Communication marked failed, SMS needs an assigned
# owner, and every provider is stubbed (no spec may reach a real provider).
#
# Rewritten 2026-10-01: the old spec expected the Communication itself back
# and let unstubbed sends fall through to real AWS SES.
RSpec.describe CommunicationService, type: :service do
  let(:company) { create(:company) }
  let(:owner) do
    User.create!(email: "o-#{SecureRandom.hex(3)}@example.com", first_name: 'O', last_name: 'Wner',
                 password: 'Pass1234!', company_id: company.id, role: 'admin', status: 'active')
  end
  let(:lead) { create(:lead, company: company, email: 'test@example.com', phone: '+11234567890', owner_id: owner.id) }

  before { allow(CommunicationPreferenceService).to receive(:can_send_to?).and_return(true) }

  def stub_smtp(result = { success: true, external_id: 'msg_123' })
    allow_any_instance_of(Providers::Email::SmtpProvider).to receive(:send_message).and_return(result)
  end

  def send_email(**opts)
    CommunicationService.send_communication(communicable: lead, channel: 'email', to: 'test@example.com',
                                            subject: 'Test', body: 'Test body', provider: :smtp, **opts)
  end

  describe '.send_communication' do
    it 'creates the communication and returns it in a successful result' do
      stub_smtp

      result = nil
      expect { result = send_email }.to change(Communication, :count).by(1)

      expect(result).to include(success: true)
      expect(result[:communication]).to have_attributes(communicable: lead, channel: 'email', direction: 'outbound',
                                                        to_address: 'test@example.com', subject: 'Test',
                                                        provider: 'smtp', company_id: company.id)
    end

    it 'records the external id and a sent event' do
      stub_smtp(success: true, external_id: 'msg_456')

      communication = send_email(from: 'from@example.com', category: 'marketing')[:communication]

      expect(communication.external_id).to eq('msg_456')
      expect(communication.from_address).to eq('from@example.com')
      expect(communication.metadata['category']).to eq('marketing')
      expect(communication.communication_events.pluck(:event_type)).to include('sent')
    end

    it 'refuses a recipient who opted out' do
      allow(CommunicationPreferenceService).to receive(:can_send_to?).and_return(false)

      expect { send_email(category: 'marketing') }.to raise_error(CommunicationService::OptOutError)
    end

    it 'reports a provider failure and marks the communication failed' do
      allow_any_instance_of(Providers::Email::SmtpProvider).to receive(:send_message)
        .and_raise(StandardError, 'Network error')

      result = send_email

      expect(result).to include(success: false)
      expect(result[:communication].reload).to have_attributes(status: 'failed')
      expect(result[:communication].error_message).to include('Network error')
    end

    it 'requires a body, and a subject for email' do
      expect { send_email(body: '') }.to raise_error(CommunicationService::Error, /Body is required/)
      expect { send_email(subject: '') }.to raise_error(CommunicationService::Error, /Subject is required/)
    end

    it 'rejects an unknown provider without sending' do
      result = send_email(provider: :carrier_pigeon)

      expect(result).to include(success: false)
      expect(result[:error]).to include('Unknown email provider')
    end
  end

  describe '.send_email' do
    it 'sends through the channel helper' do
      stub_smtp

      result = CommunicationService.send_email(communicable: lead, to: 'test@example.com', subject: 'Hi',
                                               body: '<p>Hello</p>', provider: :smtp)

      expect(result[:communication]).to have_attributes(channel: 'email', subject: 'Hi')
    end
  end

  describe '.send_sms' do
    before do
      allow(SmsCapService).to receive(:check!)
      allow_any_instance_of(Providers::Sms::TwilioProvider).to receive(:send_message)
        .and_return({ success: true, external_id: 'SM123' })
    end

    it 'sends through Twilio, normalizing a bare US number' do
      result = CommunicationService.send_sms(communicable: lead, to: '303-555-0100', body: 'Hello', provider: :twilio,
                                             from: '+17205550199')

      expect(result[:communication]).to have_attributes(channel: 'sms', to_address: '+13035550100', provider: 'twilio')
      expect(result[:communication].metadata['assigned_user_id']).to eq(owner.id)
    end

    # Without an owner it falls back to any active user in the company, so it
    # only refuses when there is nobody to send as.
    it 'refuses when there is no owner and no active user to send as' do
      lead.update_columns(owner_id: nil)
      owner.update_columns(status: 'inactive')

      expect { CommunicationService.send_sms(communicable: lead, to: '+13035550100', body: 'Hi', provider: :twilio) }
        .to raise_error(CommunicationService::Error, /requires an assigned user/)
    end
  end

  describe '.send_quote_email' do
    it 'sends the quote with its id in the metadata' do
      stub_smtp
      quote = create(:quote, company: company)

      result = CommunicationService.send_quote_email(quote: quote, to: 'buyer@example.com', provider: :smtp)

      expect(result[:communication]).to have_attributes(communicable: quote, channel: 'email')
      expect(result[:communication].metadata).to include('quote_id' => quote.id, 'category' => 'quotes')
    end
  end
end
