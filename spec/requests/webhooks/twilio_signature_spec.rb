# frozen_string_literal: true

require 'rails_helper'

# Twilio signs each webhook with the sending account's auth token. Production
# keeps that token in Platform Settings, not ENV, and the check read ENV only,
# so every request went through unchecked. It now finds the token where the rest
# of the code does, and stays log-only until TWILIO_SIGNATURE_MODE=enforce.
RSpec.describe 'Twilio webhook signatures', type: :request do
  let(:token)  { 'mastertoken' }
  let(:params) { { 'MessageSid' => 'SMunknown', 'MessageStatus' => 'delivered', 'AccountSid' => 'ACmaster' } }
  let(:mode)   { nil }

  before do
    allow(TwilioSmsService).to receive(:master_credentials).and_return(['ACmaster', token])
    allow(ENV).to receive(:[]).and_call_original
    allow(ENV).to receive(:[]).with('TWILIO_SIGNATURE_MODE').and_return(mode)
    allow(ENV).to receive(:[]).with('RAILS_API_URL').and_return('https://api.example.com')
    allow(ENV).to receive(:[]).with('API_BASE_URL').and_return(nil)
  end

  def sign(url, with: token, body: params)
    Twilio::Security::RequestValidator.new(with).build_signature_for(url, body)
  end

  def post_status(signature, body: params)
    headers = signature ? { 'X-Twilio-Signature' => signature } : {}
    post '/webhooks/twilio/sms/status', params: body, headers: headers
  end

  context 'enforced' do
    let(:mode) { 'enforce' }

    it 'lets a request signed for the address it reached us on through' do
      post_status(sign('http://www.example.com/webhooks/twilio/sms/status'))
      expect(response).to have_http_status(:ok)
    end

    it 'lets a request signed for https through when a proxy hands us http' do
      post_status(sign('https://www.example.com/webhooks/twilio/sms/status'))
      expect(response).to have_http_status(:ok)
    end

    it 'lets a request signed for our API origin through when a proxy hands us its own host' do
      post_status(sign('https://api.example.com/webhooks/twilio/sms/status'))
      expect(response).to have_http_status(:ok)
    end

    it 'turns away a forged signature' do
      post_status(sign('http://www.example.com/webhooks/twilio/sms/status', with: 'not-our-token'))
      expect(response).to have_http_status(:forbidden)
    end

    it 'turns away a request with no signature' do
      post_status(nil)
      expect(response).to have_http_status(:forbidden)
    end

    it 'checks a dealer\'s own account against their token' do
      company = Company.create!(name: "Own-#{SecureRandom.hex(4)}")
      TwilioAccount.create!(company: company, phone_number: '+13525588888', phone_number_sid: 'PNown', status: 'active',
                            sub_account_sid: 'ACdealer', auth_token: 'dealertoken', metadata: { 'own_account' => true })
      body = params.merge('AccountSid' => 'ACdealer')

      post_status(sign('http://www.example.com/webhooks/twilio/sms/status', with: 'dealertoken', body: body), body: body)
      expect(response).to have_http_status(:ok)

      post_status(sign('http://www.example.com/webhooks/twilio/sms/status', body: body), body: body)
      expect(response).to have_http_status(:forbidden)
    end
    it 'checks an account a dealer typed into Communications settings against the token saved there' do
      sid = "AC#{'e8' * 16}"
      company = Company.create!(name: "Typed-#{SecureRandom.hex(4)}")
      Setting.set('Company', company.id, 'communications',
                  { 'sms' => { 'provider' => 'twilio', 'twilioAccountSid' => sid, 'twilioAuthToken' => 'typedtoken' } })
      body = params.merge('AccountSid' => sid)

      post_status(sign('http://www.example.com/webhooks/twilio/sms/status', with: 'typedtoken', body: body), body: body)
      expect(response).to have_http_status(:ok)

      post_status(sign('http://www.example.com/webhooks/twilio/sms/status', body: body), body: body)
      expect(response).to have_http_status(:forbidden)
    end
  end

  context 'log only (the default)' do
    it 'lets a forged request through and says it would have turned it away' do
      allow(Rails.logger).to receive(:warn).and_call_original
      post_status(sign('http://www.example.com/webhooks/twilio/sms/status', with: 'not-our-token'))

      expect(response).to have_http_status(:ok)
      expect(Rails.logger).to have_received(:warn).with(/Signature check would reject \(log only\): Invalid signature/)
    end
  end
end
