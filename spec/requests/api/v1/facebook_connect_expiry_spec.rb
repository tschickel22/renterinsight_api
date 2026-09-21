# frozen_string_literal: true

require 'rails_helper'

# Disconnecting and reconnecting is what a user does when the screen says the
# token expired, and it did not clear the expiry: connect_page wrote every
# other field and left token_expires_at alone, so a stale stamp survived and
# the reconnected page still read "Expired". Seen on production integration 2
# on 2026-09-21, reconnected at 17:10 and still carrying a 16:50 expiry.
RSpec.describe 'Connecting a Facebook page records its expiry', type: :request do
  let(:company) { Company.create!(name: "FBConn-#{SecureRandom.hex(4)}") }
  let(:user) do
    User.create!(email: "u-#{SecureRandom.hex(4)}@example.com", first_name: 'T', last_name: 'U',
                 password: 'Pass1234!', company_id: company.id, role: 'platform_admin')
  end
  let(:token)   { JsonWebToken.encode(user_id: user.id, company_id: company.id) }
  let(:headers) { { 'Authorization' => "Bearer #{token}", 'Content-Type' => 'application/json' } }

  let!(:stale) do
    company.facebook_integrations.create!(
      page_id: '55501', page_name: 'Test Page', page_access_token: 'old-page-token',
      user_access_token: 'old-user-token', status: 'expired', token_expires_at: 2.hours.ago
    )
  end

  before do
    allow(MetaGraphApi).to receive(:subscribe_page_to_webhooks).and_return({ 'success' => true })
    allow(MetaGraphApi).to receive(:get).and_return({})
  end

  def connect!
    post '/api/v1/integrations/facebook/connect_page',
         params: { page_id: '55501', page_name: 'Test Page',
                   page_access_token: 'new-page-token', user_access_token: 'new-user-token' }.to_json,
         headers: headers
  end

  it 'replaces a stale expiry with the one the new token actually has' do
    allow(MetaGraphApi).to receive(:debug_token).with('new-user-token')
      .and_return({ 'data' => { 'is_valid' => true, 'expires_at' => 60.days.from_now.to_i } })

    connect!

    expect(response).to have_http_status(:ok)
    stale.reload
    expect(stale.status).to eq('active')
    expect(stale.token_expires_at).to be > 30.days.from_now
  end

  # The common case: Facebook hands back a token that does not expire. That has
  # to clear the old stamp, not leave it behind.
  it 'clears the old expiry when the new token does not expire' do
    allow(MetaGraphApi).to receive(:debug_token).and_return({ 'data' => { 'expires_at' => 0 } })

    connect!

    expect(stale.reload.token_expires_at).to be_nil

    get '/api/v1/integrations/facebook/status', headers: headers
    expect(JSON.parse(response.body)['token_expired']).to be false
  end

  # Graph being unreachable must not block the connection or leave the old
  # stamp in place, since the old stamp is what said "expired".
  it 'connects anyway when Graph will not say, rather than keeping the old stamp' do
    allow(MetaGraphApi).to receive(:debug_token).and_raise(MetaGraphApi::Error.new('down'))

    connect!

    expect(response).to have_http_status(:ok)
    expect(stale.reload.token_expires_at).to be_nil
  end
end
