# frozen_string_literal: true

require 'rails_helper'

# Workflows, nurture steps, quotes and other CommunicationService texts go out
# through this provider. On a dealer's own connected Twilio number they must use
# the dealer's account, leave our Messaging Service off, and ask Twilio for
# delivery updates, since no service of ours reports them for that account.
RSpec.describe Providers::Sms::TwilioProvider do
  let(:dealer_sid) { "AC#{'e8' * 16}" }
  let(:company) { Company.create!(name: "Own #{SecureRandom.hex(4)}", sms_provisioning_mode: 'dedicated') }
  let(:sent) { [] }

  before do
    allow(TwilioSmsService).to receive(:master_credentials).and_return(%w[ACmaster mastertoken])
    allow(TwilioProvisioningService).to receive(:api_base_url).and_return('https://api.example.com')
    TwilioAccount.create!(company: company, phone_number: '+13525588888', phone_number_sid: 'PNown', status: 'active',
                          sub_account_sid: dealer_sid, auth_token: 'dealertoken', metadata: { 'own_account' => true })
    allow(Net::HTTP).to receive(:start) do |*_args, **_opts, &blk|
      http = double('http')
      allow(http).to receive(:request) do |req|
        sent << { path: req.path, form: URI.decode_www_form(req.body).to_h }
        double(code: '201', body: { sid: 'SMok', status: 'queued' }.to_json)
      end
      blk.call(http)
    end
  end

  it 'sends on the dealer\'s account from their number and asks for delivery updates' do
    result = described_class.new(company: company).send_message(to: '+13035709810', body: 'hi')

    expect(result[:external_id]).to eq('SMok')
    expect(sent.last[:path]).to include("/Accounts/#{dealer_sid}/")
    expect(sent.last[:form]).to include('From' => '+13525588888',
                                        'StatusCallback' => 'https://api.example.com/webhooks/twilio/sms/status')
    expect(sent.last[:form]).not_to have_key('MessagingServiceSid')
  end
end
