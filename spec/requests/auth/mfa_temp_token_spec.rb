# frozen_string_literal: true

require 'rails_helper'

# Login answers a user with MFA turned on with a short-lived temp token and no
# access token, then waits for the code. The temp token is signed with the same
# secret and carries user_id, and ApplicationController#authenticate used to
# accept any JWT it could decode, so the temp token alone opened every
# endpoint: MFA was skippable with just the password.
RSpec.describe 'MFA temp token', type: :request do
  let(:company) { create(:company) }
  let(:user) do
    User.create!(email: "m-#{SecureRandom.hex(4)}@example.com", first_name: 'M', last_name: 'F',
                 password: 'Pass1234!', company_id: company.id, role: 'company_admin')
  end

  it 'is refused by authenticated endpoints' do
    temp = JsonWebToken.generate_mfa_temp_token(user)

    get '/api/crm/leads', headers: { 'Authorization' => "Bearer #{temp}" }

    expect(response).to have_http_status(:unauthorized)
  end

  it 'refuses the portal variant too' do
    temp = JsonWebToken.encode({ user_id: user.id, type: 'mfa_temp_portal' }, 5.minutes.from_now)

    get '/api/crm/leads', headers: { 'Authorization' => "Bearer #{temp}" }

    expect(response).to have_http_status(:unauthorized)
  end

  it 'still lets a real access token through' do
    get '/api/crm/leads', headers: { 'Authorization' => "Bearer #{JsonWebToken.generate_access_token(user)}" }

    expect(response).to have_http_status(:ok)
  end
end

# The first fix only covered ApplicationController#authenticate. Several
# controllers decode the JWT themselves, and one of them can turn MFA off.
RSpec.describe 'MFA temp token outside ApplicationController', type: :request do
  let(:company) { create(:company) }
  let(:user) do
    User.create!(email: "m-#{SecureRandom.hex(4)}@example.com", first_name: 'M', last_name: 'F',
                 password: 'Pass1234!', company_id: company.id, role: 'company_admin', status: 'active')
  end

  it 'cannot turn MFA off through user settings' do
    temp = JsonWebToken.generate_mfa_temp_token(user)

    patch '/api/v1/user_settings/security', params: { mfa_enabled: false },
                                             headers: { 'Authorization' => "Bearer #{temp}" }

    expect(response).to have_http_status(:unauthorized)
  end

  it 'cannot open the buyer portal with only the portal password' do
    access = create(:buyer_portal_access)
    temp = JsonWebToken.generate_mfa_temp_token_portal(access)

    get '/api/portal/truebuild_designs', headers: { 'Authorization' => "Bearer #{temp}" }

    expect(response).to have_http_status(:unauthorized)
  end

  it 'is still accepted by the MFA verify step it exists for' do
    temp = JsonWebToken.generate_mfa_temp_token(user)

    post '/api/auth/mfa/verify_code', params: { temp_token: temp, code: '000000' }

    expect(response.body).not_to include('Invalid or expired temporary token')
  end
end
