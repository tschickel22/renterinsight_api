# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'Platform settings access', type: :request do
  let(:company) { create(:company) }

  def user_with_role(role, email)
    User.create!(email: email, password: 'Password123!', company: company,
                 first_name: 'Test', last_name: 'User', role: role)
  end

  def auth_headers(user)
    { 'Authorization' => "Bearer #{JsonWebToken.encode(user_id: user.id, company_id: company.id)}" }
  end

  before do
    Setting.set('Platform', 0, 'communications', {
                  'email' => {
                    'provider' => 'aws_ses', 'fromEmail' => 'alerts@example.com', 'fromName' => 'Platform',
                    'smtpHost' => 'smtp.example.com', 'smtpUsername' => 'admin@example.com',
                    'smtpPassword' => 'encrypted:abc', 'awsAccessKeyId' => 'AKIAEXAMPLE',
                    'awsSecretAccessKey' => 'encrypted:def', 'isEnabled' => true
                  },
                  'sms' => {
                    'provider' => 'twilio', 'fromNumber' => '+15551234567',
                    'twilioAccountSid' => 'ACsecret', 'twilioAuthToken' => 'encrypted:ghi',
                    'isEnabled' => true
                  }
                })
  end

  describe 'GET /api/platform/settings' do
    it 'gives an unauthenticated caller the brand kernel only' do
      get '/api/platform/settings'

      expect(response).to have_http_status(:ok)
      body = response.parsed_body
      expect(body).to have_key('general')
      expect(body).to have_key('branding')
      expect(body).not_to have_key('communications')
      expect(response.body).not_to include('ACsecret')
      expect(response.body).not_to include('AKIAEXAMPLE')
    end

    it 'gives a signed-in non-admin the delivery summary but no credentials or account identifiers' do
      get '/api/platform/settings', headers: auth_headers(user_with_role('user', 'rep@example.com'))

      sms = response.parsed_body.dig('communications', 'sms')
      email = response.parsed_body.dig('communications', 'email')

      expect(sms).to eq('provider' => 'twilio', 'fromNumber' => '+15551234567', 'isEnabled' => true)
      expect(email).to eq('provider' => 'aws_ses', 'fromEmail' => 'alerts@example.com',
                          'fromName' => 'Platform', 'isEnabled' => true)
      expect(response.body).not_to include('ACsecret')
      expect(response.body).not_to include('AKIAEXAMPLE')
      expect(response.body).not_to include('smtp.example.com')
    end

    it 'gives a platform admin the full config with secrets masked' do
      get '/api/platform/settings', headers: auth_headers(user_with_role('platform_admin', 'admin@example.com'))

      sms = response.parsed_body.dig('communications', 'sms')
      expect(sms['twilioAccountSid']).to eq('ACsecret')
      expect(sms['twilioAuthToken']).to eq(CommunicationSecrets::MASKED_PLACEHOLDER)
      expect(response.parsed_body).to have_key('warranty')
    end
  end

  describe 'PUT /api/platform/settings' do
    it 'refuses a signed-in non-admin' do
      put '/api/platform/settings',
          params: { communications: { sms: { fromNumber: '+15550000000' } } },
          headers: auth_headers(user_with_role('user', 'rep2@example.com'))

      expect(response).to have_http_status(:forbidden)
      expect(Setting.get('Platform', 0, 'communications').dig('sms', 'fromNumber')).to eq('+15551234567')
    end

    it 'refuses an unauthenticated caller' do
      put '/api/platform/settings', params: { communications: { sms: { fromNumber: '+15550000000' } } }

      expect(response).to have_http_status(:unauthorized)
    end

    it 'allows a platform admin' do
      put '/api/platform/settings',
          params: { communications: { sms: { fromNumber: '+15550000000' } } },
          headers: auth_headers(user_with_role('platform_admin', 'admin2@example.com'))

      expect(response).to have_http_status(:ok)
      expect(Setting.get('Platform', 0, 'communications').dig('sms', 'fromNumber')).to eq('+15550000000')
    end

    it 'does not let a partial save delete the channel it omitted' do
      put '/api/platform/settings',
          params: { communications: { sms: { fromNumber: '+15550000000' } } },
          headers: auth_headers(user_with_role('platform_admin', 'admin3@example.com'))

      email = Setting.get('Platform', 0, 'communications')['email']
      expect(email['awsSecretAccessKey']).to eq('encrypted:def')
      expect(email['fromEmail']).to eq('alerts@example.com')
    end
  end
end
