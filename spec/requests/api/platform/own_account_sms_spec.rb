# frozen_string_literal: true

require 'rails_helper'

# A text typed on a lead goes out through Api::Platform::CommunicationsController#sms,
# which reads the settings waterfall and knew nothing of a dealer's own number
# connected as if we had provisioned it. It also put our Messaging Service on
# whatever account it sent with, and Twilio answers 404 for another account's
# service: "The requested resource /2010-04-01/Accounts/AC.../Messages.json was
# not found" (Easy Homesource, 2026-10-21).
RSpec.describe 'Api::Platform SMS from a dealer\'s own Twilio account', type: :request do
  let(:dealer_sid) { "AC#{'e8' * 16}" }
  let(:company) { Company.create!(name: "Own #{SecureRandom.hex(4)}", industry: 'manufactured_housing') }
  let(:admin) do
    User.create!(email: "pa-#{SecureRandom.hex(4)}@example.com", first_name: 'P', last_name: 'A',
                 password: 'Pass1234!', company_id: company.id, role: 'platform_admin')
  end
  let(:headers) { { 'Authorization' => "Bearer #{JsonWebToken.encode(user_id: admin.id, company_id: company.id)}" } }
  let(:sent) { [] }

  before do
    allow(TwilioSmsService).to receive(:master_credentials).and_return(%w[ACmaster mastertoken])
    allow(TwilioSmsService).to receive(:master_messaging_service_sid).and_return('MGmaster')
    allow(Net::HTTP).to receive(:start) do |*_args, **_opts, &blk|
      http = double('http')
      allow(http).to receive(:request) do |req|
        sent << { path: req.path, form: URI.decode_www_form(req.body).to_h }
        double(code: '201', body: { sid: 'SMok', status: 'queued' }.to_json)
      end
      blk.call(http)
    end
  end

  def send_text
    post '/api/platform/communications/sms', params: { to: '+13035709810', message: 'test text' }, headers: headers
  end

  it 'sends a connected own number on the dealer\'s account, from that number, with no Messaging Service' do
    company.update!(sms_provisioning_mode: 'dedicated')
    TwilioAccount.create!(company: company, phone_number: '+13525588888', phone_number_sid: 'PNown', status: 'active',
                          sub_account_sid: dealer_sid, auth_token: 'dealertoken', metadata: { 'own_account' => true })

    send_text

    expect(response).to have_http_status(:ok)
    expect(sent.last[:path]).to include("/Accounts/#{dealer_sid}/")
    expect(sent.last[:form]).to include('From' => '+13525588888')
    expect(sent.last[:form]).not_to have_key('MessagingServiceSid')
  end

  it 'keeps our Messaging Service off an account typed into settings' do
    Setting.set('Company', company.id, 'communications', {
      'sms' => { 'provider' => 'twilio', 'isEnabled' => true, 'fromNumber' => '1352-558-8888',
                 'twilioAccountSid' => dealer_sid, 'twilioAuthToken' => 'typedtoken' }
    })

    send_text

    expect(sent.last[:path]).to include("/Accounts/#{dealer_sid}/")
    expect(sent.last[:form]).not_to have_key('MessagingServiceSid')
  end

  it 'still sends our own account through our Messaging Service' do
    Setting.set('Company', company.id, 'communications', {
      'sms' => { 'provider' => 'twilio', 'isEnabled' => true, 'fromNumber' => '+17205752095',
                 'twilioAccountSid' => 'ACmaster', 'twilioAuthToken' => 'mastertoken' }
    })

    send_text

    expect(sent.last[:path]).to include('/Accounts/ACmaster/')
    expect(sent.last[:form]).to include('MessagingServiceSid' => 'MGmaster', 'From' => '+17205752095')
  end
end
