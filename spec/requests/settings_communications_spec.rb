# frozen_string_literal: true

require 'rails_helper'

# /api/settings is the generic setting endpoint the company Email/SMS screens
# actually save through. `communications` carries credentials, so it needs the
# same mask-restore + encrypt-at-rest handling as the dedicated controllers.
RSpec.describe 'Settings — communications secrets', type: :request do
  # RBAC is exercised elsewhere; these specs are about the secret handling, so
  # take skip_rbac?'s non-RBAC path rather than wiring up permission records.
  let(:company) { create(:company, use_rbac_system: false) }
  let(:user) do
    User.create!(email: 'admin@example.com', password: 'Password123!', company: company,
                 first_name: 'Admin', last_name: 'User')
  end
  let(:headers) { { 'Authorization' => "Bearer #{JsonWebToken.encode(user_id: user.id, company_id: company.id)}" } }

  let(:real_token) { 'a1b2c3d4e5f6a7b8c9d0e1f2a3b4c5d6' }

  def stored_communications
    Setting.get('Company', company.id, 'communications')
  end

  def put_communications(sms)
    put '/api/settings', params: { key: 'communications', value: { 'sms' => sms } }, headers: headers
  end

  describe 'writing' do
    it 'encrypts a new secret at rest instead of storing it in the clear' do
      put_communications('provider' => 'twilio', 'twilioAuthToken' => real_token)

      expect(response).to have_http_status(:ok)
      stored = stored_communications.dig('sms', 'twilioAuthToken')
      expect(stored).to start_with('encrypted:')
      expect(stored).not_to include(real_token)
    end

    it 'keeps the stored secret when the client posts the mask back' do
      put_communications('provider' => 'twilio', 'twilioAuthToken' => real_token)
      encrypted = stored_communications.dig('sms', 'twilioAuthToken')

      put_communications('provider' => 'twilio', 'twilioAuthToken' => CommunicationSecrets::MASKED_PLACEHOLDER)

      expect(stored_communications.dig('sms', 'twilioAuthToken')).to eq(encrypted)
    end

    it 'keeps the stored secret when the field comes back blank' do
      put_communications('provider' => 'twilio', 'twilioAuthToken' => real_token)
      encrypted = stored_communications.dig('sms', 'twilioAuthToken')

      put_communications('provider' => 'twilio', 'twilioAuthToken' => '')

      expect(stored_communications.dig('sms', 'twilioAuthToken')).to eq(encrypted)
    end

    it 'echoes the mask rather than the ciphertext it just wrote' do
      put_communications('provider' => 'twilio', 'twilioAuthToken' => real_token)

      echoed = response.parsed_body.dig('setting', 'value', 'sms', 'twilioAuthToken')
      expect(echoed).to eq(CommunicationSecrets::MASKED_PLACEHOLDER)
    end
  end

  describe 'reading' do
    before { put_communications('provider' => 'twilio', 'twilioAuthToken' => real_token) }

    it 'masks the secret on the scoped read' do
      get '/api/settings', params: { key: 'communications', scope_type: 'Company', scope_id: company.id },
                           headers: headers

      expect(response.parsed_body.dig('value', 'sms', 'twilioAuthToken'))
        .to eq(CommunicationSecrets::MASKED_PLACEHOLDER)
      expect(response.body).not_to include('encrypted:')
    end

    it 'masks the secret on the merged tenant view' do
      get '/api/settings/tenant', headers: headers

      expect(response.body).not_to include('encrypted:')
      expect(response.body).not_to include(real_token)
    end

    it 'masks platform secrets' do
      Setting.set('Platform', 0, 'communications',
                  { 'sms' => { 'provider' => 'twilio', 'twilioAuthToken' => 'encrypted:whatever' } })

      get '/api/settings/platform', headers: headers

      expect(response.parsed_body.dig('communications', 'sms', 'twilioAuthToken'))
        .to eq(CommunicationSecrets::MASKED_PLACEHOLDER)
      expect(response.body).not_to include('encrypted:')
    end
  end

  describe 'round-tripping the masked read back into a save' do
    it 'survives read → save → read with the secret intact' do
      put_communications('provider' => 'twilio', 'twilioAuthToken' => real_token)

      get '/api/settings', params: { key: 'communications', scope_type: 'Company', scope_id: company.id },
                           headers: headers
      masked = response.parsed_body['value']

      put '/api/settings', params: { key: 'communications', value: masked }, headers: headers

      encrypted = stored_communications.dig('sms', 'twilioAuthToken')
      expect(encrypted).to start_with('encrypted:')
      # 32-byte plaintext → 48 chars of base64 ciphertext. A stored mask would be 36.
      expect(encrypted.sub('encrypted:', '').split('--').first.length).to eq(48)
    end
  end
end
