# frozen_string_literal: true

require 'rails_helper'

# Every production run of the demo company seeder used to email its made-up
# buyers at gmail.com, yahoo.com and real lender domains (about 80 a run, with
# hard bounces). Demo data now uses reserved addresses, and the platform never
# hands one to a provider.
RSpec.describe ReservedRecipient do
  around do |ex|
    was = described_class.enforced
    described_class.enforced = true
    ex.run
  ensure
    described_class.enforced = was
  end

  describe '.email?' do
    it 'recognises example.com, .net, .org and their subdomains' do
      ["a@example.com", "b@example.net", "c@example.org", "tammyf@gmail.example.com", "admin@acme.example.com",
         %q{"Tammy" <t@Example.COM>}].each { |a| expect(described_class.email?(a)).to be(true), a }
    end

    it 'recognises the reserved TLDs' do
      %w[a@shop.test b@x.example c@nowhere.invalid d@box.localhost].each do |a|
        expect(described_class.email?(a)).to be(true), a
      end
    end

    it 'leaves real-looking domains alone' do
      %w[tammyf@gmail.com rchen@21stmortgage.com someone@notexample.com x@example.com.au admin@acmedemo.com
         ''].each { |a| expect(described_class.email?(a)).to be(false), a }
    end
  end

  describe '.phone?' do
    it 'recognises any number on the 555 exchange, however it is typed' do
      ['(260) 555-0194', '260-555-4002', '+12605550100', '12605555001'].each do |n|
        expect(described_class.phone?(n)).to be(true), n
      end
    end

    it 'leaves real numbers alone, including a 555 area code' do
      ['(260) 227-0394', '+17205752095', '(555) 227-0394', ''].each do |n|
        expect(described_class.phone?(n)).to be(false), n
      end
    end
  end

  it 'blocks nothing when not enforced' do
    described_class.enforced = false
    expect(described_class.block?('email', 'a@example.com')).to be(false)
    expect(described_class.block_phone?('260-555-0100')).to be(false)
    expect(described_class.reject_emails(['a@example.com'])).to eq(['a@example.com'])
  end

  it 'drops reserved cc/bcc entries and keeps the rest, in the shape it was given' do
    expect(described_class.reject_emails(['a@example.com', 'real@dealer.com'])).to eq(['real@dealer.com'])
    expect(described_class.reject_emails('a@example.com, real@dealer.com')).to eq('real@dealer.com')
    expect(described_class.reject_emails('a@example.com')).to be_nil
  end

  describe 'CommunicationService' do
    let(:lead) { create(:lead, email: 'buyer@gmail.example.com') }

    # Which email provider a send resolves to depends on platform settings, so
    # stand a recording one in for whichever it would be.
    let(:provider_calls) { [] }
    let(:fake_provider) do
      calls = provider_calls
      Class.new do
        define_method(:initialize) { |**| }
        define_method(:send_message) { |**kw| calls << kw; { success: true, external_id: 'msg_1' } }
      end
    end

    before do
      allow(CommunicationPreferenceService).to receive(:can_send_to?).and_return(true)
      allow_any_instance_of(CommunicationService).to receive(:get_provider_class).and_return(fake_provider)
    end

    it 'records a send to a reserved address without calling the provider' do
      result = CommunicationService.send_communication(
        communicable: lead, channel: 'email', to: 'buyer@gmail.example.com', subject: 'Hi', body: 'Body'
      )

      comm = result[:communication].reload
      expect(provider_calls).to be_empty
      expect(result[:success]).to be(true)
      expect(result[:not_delivered]).to eq('reserved_address')
      expect(comm.status).to eq('sent')
      expect(comm.external_id).to be_nil
      expect(comm.metadata['not_delivered']).to eq('reserved_address')
    end

    it 'still sends to a real address, minus any reserved cc' do
      CommunicationService.send_communication(
        communicable: lead, channel: 'email', to: 'buyer@dealer.com', subject: 'Hi', body: 'Body',
        cc: 'demo@acme.example.com, boss@dealer.com'
      )

      expect(provider_calls.size).to eq(1)
      expect(provider_calls.first).to include(to: 'buyer@dealer.com', cc: 'boss@dealer.com')
    end
  end

  describe 'Twilio' do
    it 'TwilioSmsService never posts to Twilio for a 555 number' do
      expect(Net::HTTP).not_to receive(:start)

      result = TwilioSmsService.send(to: '(260) 555-0194', body: 'Hi', from_number: '+17205550100',
                                     account_sid: 'AC1', auth_token: 'tok')
      expect(result).to include(success: true, status: 'not_delivered')
    end
  end

  describe 'mail interceptor' do
    let(:mailer) do
      Class.new(ActionMailer::Base) do
        def self.name = 'ReservedSpecMailer'

        def note(to:, cc: nil)
          mail(to: to, cc: cc, from: 'platform@dealertide.com', subject: 'Note', body: 'Body')
        end
      end
    end

    before { ActionMailer::Base.deliveries.clear }

    it 'does not deliver when every recipient is reserved' do
      mailer.note(to: 'admin@acme.example.com').deliver_now
      expect(ActionMailer::Base.deliveries).to be_empty
    end

    it 'delivers to the real recipients and drops the reserved ones' do
      mailer.note(to: ['admin@acme.example.com', 'tom@dealer.com'], cc: 'x@acme.example.com').deliver_now

      sent = ActionMailer::Base.deliveries.last
      expect(sent.to).to eq(['tom@dealer.com'])
      expect(sent.cc).to be_blank
    end
  end
end
