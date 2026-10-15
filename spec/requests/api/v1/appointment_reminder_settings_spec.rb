# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'Api::V1 appointment reminder settings', type: :request do
  let(:company) { Company.create!(name: "Co-#{SecureRandom.hex(4)}") }
  let(:admin) do
    User.create!(email: "a-#{SecureRandom.hex(4)}@ex.com", first_name: 'A', last_name: 'D', password: 'Pass1234!',
                 company_id: company.id, role: 'company_admin')
  end
  let(:headers) { { 'Authorization' => "Bearer #{JsonWebToken.encode(user_id: admin.id, company_id: company.id)}", 'Content-Type' => 'application/json' } }

  it 'is on by default, day before and hour before, text and email, with invites' do
    get '/api/v1/company/appointment-reminders', headers: headers
    expect(JSON.parse(response.body)['settings']).to eq('enabled' => true, 'offsets' => %w[day_before hour_before], 'channels' => %w[sms email], 'invites' => true)
  end

  it 'saves only known times and channels' do
    put '/api/v1/company/appointment-reminders', headers: headers,
        params: { enabled: false, offsets: %w[two_hours_before weekly], channels: %w[sms fax], invites: false }.to_json
    expect(JSON.parse(response.body)['settings']).to eq('enabled' => false, 'offsets' => %w[two_hours_before], 'channels' => %w[sms], 'invites' => false)
  end
end
