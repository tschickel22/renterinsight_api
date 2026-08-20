# frozen_string_literal: true

require 'rails_helper'

# Biometric unlock for the two audiences that need it most. A rep signs in daily
# and remembers their password; a customer signs in a handful of times across a
# purchase, and a contractor gets in from an emailed link they have to find
# again.
RSpec.describe 'Biometric unlock for customers and contractors', type: :request do
  let(:company) { Company.create!(name: "Co-#{SecureRandom.hex(4)}") }

  describe 'customer portal' do
    let(:buyer) do
      Contact.create!(company_id: company.id, first_name: 'B', last_name: 'Uyer',
                      email: "b-#{SecureRandom.hex(3)}@example.com")
    end
    let(:access) do
      BuyerPortalAccess.create!(buyer: buyer, company_id: company.id,
                                email: "p-#{SecureRandom.hex(3)}@example.com",
                                password: 'Password123!', password_confirmation: 'Password123!')
    end
    let(:headers) do
      { 'Authorization' => "Bearer #{JsonWebToken.encode(buyer_portal_access_id: access.id)}" }
    end

    def enrol
      post '/api/portal/device-sessions', params: { platform: 'ios', device_label: 'iPhone' }, headers: headers
      JSON.parse(response.body)['device_token']
    end

    it 'refuses to enrol without a portal session' do
      post '/api/portal/device-sessions', params: { platform: 'ios' }
      expect(response).to have_http_status(:unauthorized)
    end

    it 'enrols and stores only the digest' do
      raw = enrol

      expect(response).to have_http_status(:created)
      expect(DeviceSession.last.owner).to eq(access)
      expect(DeviceSession.find_by(token_digest: DeviceSession.digest(raw))).to be_present
    end

    it 'exchanges for a portal token, not a staff one' do
      raw = enrol

      post '/api/v1/device-sessions/exchange', params: { device_token: raw }

      expect(response).to have_http_status(:ok)
      body = JSON.parse(response.body)
      expect(body['audience']).to eq('portal')
      expect(body['buyer']['id']).to eq(buyer.id)
      expect(body).not_to have_key('user')
      # The token must address the portal, or it would authenticate as nobody.
      expect(JsonWebToken.decode(body['token'])['buyer_portal_access_id']).to eq(access.id)
    end

    it 'stops working once the dealer switches portal access off' do
      raw = enrol
      access.update!(portal_enabled: false)

      post '/api/v1/device-sessions/exchange', params: { device_token: raw }
      expect(response).to have_http_status(:unauthorized)
    end

    it 'stops working when the customer changes their password' do
      raw = enrol
      access.update!(password: 'Different5678!', password_confirmation: 'Different5678!')

      post '/api/v1/device-sessions/exchange', params: { device_token: raw }
      expect(response).to have_http_status(:unauthorized)
    end

    it 'will not let a customer see or revoke a staff phone' do
      staff = User.create!(email: "u-#{SecureRandom.hex(3)}@example.com", first_name: 'S', last_name: 'T',
                           password: 'Pass1234!', company_id: company.id)
      staff_session, = DeviceSession.issue!(owner: staff)

      get '/api/portal/device-sessions', headers: headers
      expect(JSON.parse(response.body)['device_sessions']).to be_empty

      delete "/api/portal/device-sessions/#{staff_session.id}", headers: headers
      expect(response).to have_http_status(:not_found)
      expect(staff_session.reload.revoked_at).to be_nil
    end
  end

  describe 'contractor portal' do
    let(:contractor) do
      Contractor.create!(company_id: company.id, name: "Trade-#{SecureRandom.hex(3)}",
                         email: "c-#{SecureRandom.hex(3)}@example.com", status: 'active')
    end
    let(:headers) { { 'Authorization' => 'Bearer stubbed' } }

    # Contractor tokens are signed with Rails.application.credentials
    # .secret_key_base, which is nil under test, so a real token cannot be
    # verified here. Their auth layer is stubbed rather than reimplemented: what
    # these examples cover is the device-session controller behind it.
    def sign_in_contractor
      allow_any_instance_of(Api::Contractor::BaseController)
        .to receive(:authenticate_contractor!) do |ctrl|
          ctrl.instance_variable_set(:@current_contractor, contractor)
        end
    end

    def enrol
      sign_in_contractor
      post '/api/contractor/device-sessions', params: { platform: 'android' }, headers: headers
      JSON.parse(response.body)['device_token']
    end

    it 'refuses to enrol without a contractor session' do
      post '/api/contractor/device-sessions', params: { platform: 'android' }
      expect(response).to have_http_status(:unauthorized)
    end

    it 'exchanges for a contractor token' do
      raw = enrol
      expect(response).to have_http_status(:created)

      post '/api/v1/device-sessions/exchange', params: { device_token: raw }

      expect(response).to have_http_status(:ok)
      body = JSON.parse(response.body)
      expect(body['audience']).to eq('contractor')
      expect(body['contractor']['id']).to eq(contractor.id)
      expect(body).not_to have_key('user')
    end

    it 'stops working once the contractor is deactivated' do
      raw = enrol
      contractor.update!(status: 'inactive')

      post '/api/v1/device-sessions/exchange', params: { device_token: raw }
      expect(response).to have_http_status(:unauthorized)
    end
  end
end
