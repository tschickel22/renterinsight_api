# frozen_string_literal: true

require 'rails_helper'

# Pressing Refresh Token appeared to do nothing: the refresh succeeded, stamped
# the expiry as the moment of the press, and the screen said "Expired, refresh
# required" again. And nothing renewed a connection on its own, because
# FacebookTokenRefreshJob was never scheduled.
RSpec.describe 'Facebook token refresh', type: :request do
  let(:company) { Company.create!(name: "FBTok-#{SecureRandom.hex(4)}") }
  let(:user) do
    User.create!(email: "u-#{SecureRandom.hex(4)}@example.com", first_name: 'T', last_name: 'U',
                 password: 'Pass1234!', company_id: company.id, role: 'platform_admin')
  end
  let(:token)   { JsonWebToken.encode(user_id: user.id, company_id: company.id) }
  let(:headers) { { 'Authorization' => "Bearer #{token}", 'Content-Type' => 'application/json' } }

  let!(:integration) do
    company.facebook_integrations.create!(
      page_id: '55501', page_name: 'Test Page', page_access_token: 'page-token',
      user_access_token: 'user-token', status: 'active', token_expires_at: 2.days.from_now
    )
  end

  def json = JSON.parse(response.body)

  it 'leaves a refreshed connection with an expiry in the future, not right now' do
    allow(MetaGraphApi).to receive(:exchange_token).and_return({ 'access_token' => 'NEW' })
    allow(MetaGraphApi).to receive(:debug_token).and_return({ 'data' => { 'expires_at' => 60.days.from_now.to_i } })

    post "/api/v1/facebook-integrations/#{integration.id}/refresh_token", headers: headers

    expect(response).to have_http_status(:ok)
    integration.reload
    expect(integration.status).to eq('active')
    expect(integration.token_expires_at).to be > 1.day.from_now
  end

  # The shape that made it look broken: Graph answers with no expires_in, which
  # used to become "expires now".
  it 'does not mark a token that never expires as expired' do
    allow(MetaGraphApi).to receive(:exchange_token).and_return({ 'access_token' => 'NEW' })
    allow(MetaGraphApi).to receive(:debug_token).and_return({ 'data' => { 'expires_at' => 0 } })

    post "/api/v1/facebook-integrations/#{integration.id}/refresh_token", headers: headers

    integration.reload
    expect(integration.token_expires_at).to be_nil
    expect(integration.status).to eq('active')
    # What the settings screen reads.
    get '/api/v1/integrations/facebook/status', headers: headers
    expect(json['token_expired']).to be false
  end

  # Once Facebook stops renewing, only reconnecting works, so the answer has to
  # say that rather than "refresh failed", which reads as try again.
  it 'asks for a reconnect when Facebook will not renew any more' do
    allow(MetaGraphApi).to receive(:exchange_token).and_raise(MetaGraphApi::ExpiredTokenError.new('Session has expired', code: 190))

    post "/api/v1/facebook-integrations/#{integration.id}/refresh_token", headers: headers

    expect(response).to have_http_status(:unprocessable_entity)
    expect(json['code']).to eq('reconnect_required')
    expect(json['error']).to include('Reconnect')
    expect(integration.reload.status).to eq('expired')
  end

  describe FacebookTokenRefreshJob do
    it 'is scheduled, so a connection renews without anyone pressing a button' do
      schedule = YAML.load_file(Rails.root.join('config/recurring.yml'), aliases: true)
      %w[production staging].each do |env|
        classes = schedule.fetch(env).values.map { |entry| entry['class'] }
        expect(classes).to include('FacebookTokenRefreshJob'), "not scheduled in #{env}"
      end
    end

    it 'renews a connection inside the threshold and leaves the expiry in the future' do
      allow(MetaGraphApi).to receive(:exchange_token).and_return({ 'access_token' => 'NEW' })
      allow(MetaGraphApi).to receive(:debug_token).and_return({ 'data' => { 'expires_at' => 60.days.from_now.to_i } })

      described_class.new.perform

      integration.reload
      expect(integration.user_access_token).to eq('NEW')
      expect(integration.token_expires_at).to be > 30.days.from_now
    end

    it 'marks a connection expired when Facebook refuses, so the UI can offer a reconnect' do
      allow(MetaGraphApi).to receive(:exchange_token).and_raise(MetaGraphApi::ExpiredTokenError.new('Session has expired', code: 190))

      described_class.new.perform

      expect(integration.reload.status).to eq('expired')
    end
  end
end
