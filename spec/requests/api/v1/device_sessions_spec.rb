# frozen_string_literal: true

require 'rails_helper'

# Biometric unlock. The security properties worth pinning down are that the
# token is never stored in the clear, that a revoked or aged-out one is refused,
# and that changing a password reaches the phones.
RSpec.describe 'Api::V1::DeviceSessions', type: :request do
  let(:company) { Company.create!(name: "Co-#{SecureRandom.hex(4)}") }
  let(:user) do
    User.create!(email: "u-#{SecureRandom.hex(4)}@example.com", first_name: 'Face', last_name: 'User',
                 password: 'Pass1234!', company_id: company.id, role: 'user')
  end
  let(:token) { JsonWebToken.encode(user_id: user.id, company_id: company.id) }
  let(:headers) { { 'Authorization' => "Bearer #{token}" } }

  def enrol
    post '/api/v1/device-sessions',
         params: { device_label: "Tom's iPhone", platform: 'ios', player_id: SecureRandom.uuid },
         headers: headers
    JSON.parse(response.body)['device_token']
  end

  describe 'POST /api/v1/device-sessions' do
    it 'requires a fully authenticated session to enrol' do
      post '/api/v1/device-sessions', params: { platform: 'ios' }
      expect(response).to have_http_status(:unauthorized)
    end

    it 'returns a raw token that is never stored in the clear' do
      raw = enrol

      expect(response).to have_http_status(:created)
      expect(raw).to be_present
      expect(DeviceSession.where(token_digest: raw).count).to eq(0)
      expect(DeviceSession.find_by(token_digest: DeviceSession.digest(raw))).to be_present
    end

    it 'replaces an existing session for the same phone instead of stacking' do
      player = SecureRandom.uuid
      2.times do
        post '/api/v1/device-sessions', params: { platform: 'ios', player_id: player }, headers: headers
      end

      expect(DeviceSession.active.where(user_id: user.id, player_id: player).count).to eq(1)
    end
  end

  describe 'POST /api/v1/device-sessions/exchange' do
    it 'trades the stored token for a session without a password' do
      raw = enrol

      post '/api/v1/device-sessions/exchange', params: { device_token: raw }

      expect(response).to have_http_status(:ok)
      body = JSON.parse(response.body)
      expect(body['token']).to be_present
      expect(body['user']['id']).to eq(user.id)
    end

    it 'refuses an unknown token' do
      post '/api/v1/device-sessions/exchange', params: { device_token: 'not-a-real-token' }
      expect(response).to have_http_status(:unauthorized)
    end

    it 'refuses a revoked token' do
      raw = enrol
      DeviceSession.last.revoke!('user_removed')

      post '/api/v1/device-sessions/exchange', params: { device_token: raw }
      expect(response).to have_http_status(:unauthorized)
    end

    it 'refuses an expired token' do
      raw = enrol
      DeviceSession.last.update_columns(expires_at: 1.hour.ago)

      post '/api/v1/device-sessions/exchange', params: { device_token: raw }
      expect(response).to have_http_status(:unauthorized)
    end

    it 'refuses a phone that has not been opened in a month' do
      raw = enrol
      DeviceSession.last.update_columns(last_used_at: 40.days.ago, created_at: 40.days.ago)

      post '/api/v1/device-sessions/exchange', params: { device_token: raw }
      expect(response).to have_http_status(:unauthorized)
    end

    it 'refuses once the account is suspended' do
      raw = enrol
      user.update_columns(status: 'suspended')

      post '/api/v1/device-sessions/exchange', params: { device_token: raw }
      expect(response).to have_http_status(:unauthorized)
    end

    it 'extends the expiry on each use, so a phone in daily use never asks again' do
      raw = enrol
      original = DeviceSession.last.expires_at
      DeviceSession.last.update_columns(expires_at: 2.days.from_now)

      post '/api/v1/device-sessions/exchange', params: { device_token: raw }

      expect(DeviceSession.last.expires_at).to be > original - 1.day
      expect(DeviceSession.last.use_count).to eq(1)
    end
  end

  describe 'revocation' do
    it 'drops every phone when the password changes' do
      raw = enrol

      user.update!(password: 'Different5678!', password_confirmation: 'Different5678!')

      post '/api/v1/device-sessions/exchange', params: { device_token: raw }
      expect(response).to have_http_status(:unauthorized)
    end

    it 'lets someone remove one phone from the list' do
      raw = enrol
      session_id = JSON.parse(response.body)['device_session']['id']

      delete "/api/v1/device-sessions/#{session_id}", headers: headers
      expect(response).to have_http_status(:ok)

      post '/api/v1/device-sessions/exchange', params: { device_token: raw }
      expect(response).to have_http_status(:unauthorized)
    end

    it 'will not let one user revoke another user\'s phone' do
      other = User.create!(email: "o-#{SecureRandom.hex(4)}@example.com", first_name: 'O', last_name: 'U',
                           password: 'Pass1234!', company_id: company.id, role: 'user')
      session, = DeviceSession.issue!(user: other)

      delete "/api/v1/device-sessions/#{session.id}", headers: headers

      expect(response).to have_http_status(:not_found)
      expect(session.reload.revoked_at).to be_nil
    end
  end

  describe 'GET /api/v1/device-sessions' do
    it 'lists the phones that can unlock without a password' do
      enrol

      get '/api/v1/device-sessions', headers: headers

      body = JSON.parse(response.body)
      expect(body['device_sessions'].length).to eq(1)
      expect(body['device_sessions'].first['device_label']).to eq("Tom's iPhone")
      # The token must not travel back out of the API in any form.
      expect(response.body).not_to include('token_digest')
    end
  end
end
