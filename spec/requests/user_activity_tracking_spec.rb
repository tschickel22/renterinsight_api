# frozen_string_literal: true

require 'rails_helper'

# Nothing recorded when a user was last doing something. login_activities says
# someone arrived rather than that they are here, and device_sessions.last_used_at
# moves only on a token refresh.
RSpec.describe 'User activity tracking', type: :request do
  let(:company) { Company.create!(name: "Act-#{SecureRandom.hex(3)}") }
  let(:user) do
    User.create!(email: "u-#{SecureRandom.hex(3)}@example.com", first_name: 'A', last_name: 'B',
                 password: 'Pass1234!', company_id: company.id, role: 'company_admin')
  end
  let(:headers) do
    { 'Authorization' => "Bearer #{JsonWebToken.encode(user_id: user.id, company_id: company.id)}" }
  end

  it 'records that a user was here, and where' do
    get '/api/crm/sources', headers: headers

    user.reload
    expect(user.last_active_at).to be_present
    expect(user.last_active_path).to eq('/api/crm/sources')
  end

  # One update per user per minute, not one per request. The guard reads an
  # attribute already loaded, so a request that does not need to write costs
  # nothing.
  it 'does not write again inside the throttle' do
    get '/api/crm/sources', headers: headers
    first = user.reload.last_active_at

    get '/api/crm/sources', headers: headers

    expect(user.reload.last_active_at).to eq(first)
  end

  it 'writes again once the throttle has passed' do
    get '/api/crm/sources', headers: headers
    user.update_columns(last_active_at: 5.minutes.ago)
    stale = user.reload.last_active_at

    get '/api/crm/sources', headers: headers

    expect(user.reload.last_active_at).to be > stale
  end

  it 'records nothing for a request that failed authentication' do
    get '/api/crm/sources'

    expect(user.reload.last_active_at).to be_nil
  end
end
