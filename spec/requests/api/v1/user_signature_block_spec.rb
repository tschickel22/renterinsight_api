# frozen_string_literal: true

require 'rails_helper'

# Account Settings, Signature Block.
RSpec.describe 'Signature Block', type: :request do
  let(:company) { Company.create!(name: "Co-#{SecureRandom.hex(4)}") }
  let(:user) do
    User.create!(email: "r-#{SecureRandom.hex(4)}@ex.com", first_name: 'Rita', last_name: 'Rep', password: 'Pass1234!',
                 company_id: company.id, role: 'sales_rep')
  end
  let(:headers) { { 'Authorization' => "Bearer #{JsonWebToken.encode(user_id: user.id, company_id: company.id)}", 'Content-Type' => 'application/json' } }

  it 'saves an email signature with safe formatting and a short text signature' do
    patch '/api/v1/user_settings/profile', headers: headers, params: {
      email_signature: '<p><strong>Rita Rep</strong><br>Summit Park Homes</p><script>alert(1)</script>',
      sms_signature: "  - Rita,   Summit Park  #{'x' * 80}"
    }.to_json
    expect(response).to have_http_status(:ok)

    get '/api/v1/user_settings/profile', headers: headers
    body = JSON.parse(response.body)
    expect(body['email_signature']).to include('<strong>Rita Rep</strong>')
    expect(body['email_signature']).not_to include('script')
    expect(body['sms_signature']).to start_with('- Rita, Summit Park')
    expect(body['sms_signature'].length).to eq(60)
  end

  it 'clears them when emptied' do
    user.update!(email_signature: '<p>Rita</p>', sms_signature: '- Rita')
    patch '/api/v1/user_settings/profile', headers: headers, params: { email_signature: '<p><br></p>', sms_signature: '' }.to_json
    expect(user.reload).to have_attributes(email_signature: nil, sms_signature: nil)
  end
end
