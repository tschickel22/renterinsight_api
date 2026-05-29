# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'Api::V1::SocialPostSchedules intent_notes', type: :request do
  let(:company) { Company.create!(name: "Co-#{SecureRandom.hex(4)}") }
  let(:user) do
    User.create!(email: "u-#{SecureRandom.hex(4)}@example.com", first_name: 'T', last_name: 'U',
                 password: 'Pass1234!', company_id: company.id, role: 'platform_admin')
  end
  let(:token)   { JsonWebToken.encode(user_id: user.id, company_id: company.id) }
  let(:headers) { { 'Authorization' => "Bearer #{token}", 'Content-Type' => 'application/json' } }
  let(:notes)   { { 'feature_spotlight' => 'Highlight the new analytics dashboard', 'customer_win' => '' } }

  it 'persists and serializes intent_notes on create' do
    post '/api/v1/social-post-schedules', headers: headers, params: {
      social_post_schedule: { frequency: 'weekly', intent_rotation: %w[feature_spotlight customer_win], intent_notes: notes }
    }.to_json
    expect(response).to have_http_status(:created)
    expect(JSON.parse(response.body)['intent_notes']).to eq(notes)
    expect(SocialPostSchedule.last.intent_notes).to eq(notes)
  end

  it 'updates intent_notes' do
    s = company.social_post_schedules.create!(frequency: 'weekly', intent_rotation: ['feature_spotlight'])
    patch "/api/v1/social-post-schedules/#{s.id}", headers: headers, params: {
      social_post_schedule: { intent_notes: { 'feature_spotlight' => 'New idea' } }
    }.to_json
    expect(response).to have_http_status(:ok)
    expect(s.reload.intent_notes).to eq({ 'feature_spotlight' => 'New idea' })
  end

  it 'defaults to an empty hash when not provided' do
    s = company.social_post_schedules.create!(frequency: 'weekly')
    expect(s.intent_notes).to eq({})
  end
end
