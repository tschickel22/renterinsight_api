# frozen_string_literal: true

require 'rails_helper'

# A bot on Tor was submitting the public DMS Checklist form every other day and
# trying sign-in and password reset with throwaway addresses. Nothing limited how
# fast anyone could call the endpoints that need no sign-in.
RSpec.describe 'Abuse rate limits on public endpoints', type: :request do
  before { AbuseRateLimit::STORE.clear }
  after { AbuseRateLimit::STORE.clear }

  def json_post(path, body, ip: '203.0.113.7')
    post path, params: body.to_json,
               headers: { 'CONTENT_TYPE' => 'application/json', 'HTTP_CF_CONNECTING_IP' => ip }
  end

  describe 'sign-in' do
    it 'refuses the 11th try for one email within 15 minutes' do
      10.times { json_post '/api/auth/login', { email: 'nobody@example.com', password: 'wrong' } }
      expect(response).not_to have_http_status(:too_many_requests)

      json_post '/api/auth/login', { email: 'nobody@example.com', password: 'wrong' }
      expect(response).to have_http_status(:too_many_requests)
      expect(response.headers['Retry-After']).to eq(15.minutes.to_i.to_s)
    end

    it 'counts each email apart, so one guessed account does not block the office' do
      10.times { json_post '/api/auth/login', { email: 'a@example.com', password: 'wrong' } }
      json_post '/api/auth/login', { email: 'b@example.com', password: 'wrong' }
      expect(response).not_to have_http_status(:too_many_requests)
    end

    it 'counts by the visitor address Cloudflare reports, not the edge' do
      30.times { |i| json_post '/api/auth/login', { email: "u#{i}@example.com", password: 'x' }, ip: '198.51.100.1' }
      json_post '/api/auth/login', { email: 'next@example.com', password: 'x' }, ip: '198.51.100.1'
      expect(response).to have_http_status(:too_many_requests)

      json_post '/api/auth/login', { email: 'other@example.com', password: 'x' }, ip: '198.51.100.2'
      expect(response).not_to have_http_status(:too_many_requests)
    end
  end

  describe 'password reset' do
    it 'refuses a sixth reset request for one email within the hour' do
      5.times { json_post '/api/auth/request_password_reset', { email: 'nobody@example.com' } }
      expect(response).not_to have_http_status(:too_many_requests)

      json_post '/api/auth/request_password_reset', { email: 'nobody@example.com' }
      expect(response).to have_http_status(:too_many_requests)
    end
  end

  describe 'public form submit' do
    let(:company) { Company.create!(name: 'Summit Park Homes') }
    let!(:source) { Source.find_or_create_by!(name: 'Web') { |s| s.source_type = 'web' } }
    let(:form) do
      IntakeForm.create!(company_id: company.id, name: 'Checklist', is_active: true,
                         auto_create_lead: false, schema: [], field_mappings: {})
    end

    it 'refuses the 21st submit from one address within 10 minutes and stores nothing for it' do
      20.times { json_post "/f/#{form.public_id}/submit", { 'note' => 'hi' } }
      expect(response).to have_http_status(:ok)

      expect do
        json_post "/f/#{form.public_id}/submit", { 'note' => 'hi' }
      end.not_to change(IntakeSubmission, :count)
      expect(response).to have_http_status(:too_many_requests)
    end
  end
end
