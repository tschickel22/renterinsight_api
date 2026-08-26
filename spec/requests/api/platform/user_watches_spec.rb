# frozen_string_literal: true

require 'rails_helper'

# Flagging a user and capturing what they do. Platform-side only.
RSpec.describe 'Api::Platform UserWatches', type: :request do
  let(:company) { Company.create!(name: "Watch Co #{SecureRandom.hex(4)}", industry: 'manufactured_housing') }
  let(:admin) do
    User.create!(email: "pa-#{SecureRandom.hex(4)}@example.com", first_name: 'P', last_name: 'A',
                 password: 'Pass1234!', company_id: company.id, role: 'platform_admin')
  end
  let(:subject_user) do
    User.create!(email: "sub-#{SecureRandom.hex(4)}@example.com", first_name: 'S', last_name: 'U',
                 password: 'Pass1234!', company_id: company.id, role: 'company_admin')
  end
  let(:auth) { { 'Authorization' => "Bearer #{JsonWebToken.encode(user_id: admin.id, company_id: company.id)}" } }

  after { UserActivityWatch.reset_cache! }

  describe 'flagging' do
    it 'requires a reason, because the watch is itself an audit record' do
      post '/api/platform/user_watches', params: { user_id: subject_user.id }, headers: auth

      expect(response).to have_http_status(:unprocessable_entity)
      expect(UserActivityWatch.count).to eq(0)
    end

    it 'flags a user and records who flagged them and why' do
      post '/api/platform/user_watches',
           params: { user_id: subject_user.id, reason: 'Bulk export review' }, headers: auth

      expect(response).to have_http_status(:created)
      watch = UserActivityWatch.last
      expect(watch.user_id).to eq(subject_user.id)
      expect(watch.created_by_user_id).to eq(admin.id)
      expect(watch.reason).to eq('Bulk export review')
      expect(watch.active).to be(true)
    end

    it 'does not double-flag the same user' do
      2.times do
        post '/api/platform/user_watches',
             params: { user_id: subject_user.id, reason: 'Review' }, headers: auth
      end

      expect(UserActivityWatch.where(user_id: subject_user.id).count).to eq(1)
    end

    it 'refuses a non-platform-admin' do
      tenant_token = JsonWebToken.encode(user_id: subject_user.id, company_id: company.id)
      post '/api/platform/user_watches',
           params: { user_id: subject_user.id, reason: 'Review' },
           headers: { 'Authorization' => "Bearer #{tenant_token}" }

      expect(response).to have_http_status(:forbidden)
      expect(UserActivityWatch.count).to eq(0)
    end

    it 'stops collecting but keeps what it gathered' do
      watch = UserActivityWatch.create!(user_id: subject_user.id, company_id: company.id,
                                        created_by_user_id: admin.id, reason: 'r',
                                        active: true, started_at: Time.current)
      WatchedRequest.create!(user_activity_watch_id: watch.id, user_id: subject_user.id,
                             company_id: company.id, http_method: 'GET', path: '/api/v1/leads',
                             occurred_at: Time.current)

      delete "/api/platform/user_watches/#{watch.id}", headers: auth

      expect(response).to have_http_status(:ok)
      expect(watch.reload.active).to be(false)
      expect(watch.ended_at).to be_present
      expect(watch.watched_requests.count).to eq(1)
    end
  end

  describe 'capture' do
    it 'records a watched user request trail and flags background polling' do
      UserActivityWatch.create!(user_id: subject_user.id, company_id: company.id,
                                created_by_user_id: admin.id, reason: 'r',
                                active: true, started_at: Time.current)
      UserActivityWatch.reset_cache!
      subject_auth = { 'Authorization' => "Bearer #{JsonWebToken.encode(user_id: subject_user.id, company_id: company.id)}" }

      get '/api/v1/notifications/unread_count', headers: subject_auth
      get '/api/crm/leads', headers: subject_auth

      captured = WatchedRequest.where(user_id: subject_user.id)
      expect(captured.count).to eq(2)
      expect(captured.find_by(path: '/api/v1/notifications/unread_count').is_poll).to be(true)
      expect(captured.find_by(path: '/api/crm/leads').is_poll).to be(false)
      expect(captured.first.ip_address).to be_present
    end

    it 'records nothing for an unwatched user' do
      subject_auth = { 'Authorization' => "Bearer #{JsonWebToken.encode(user_id: subject_user.id, company_id: company.id)}" }
      get '/api/crm/leads', headers: subject_auth

      expect(WatchedRequest.count).to eq(0)
    end
  end

  describe 'report' do
    let(:watch) do
      UserActivityWatch.create!(user_id: subject_user.id, company_id: company.id,
                                created_by_user_id: admin.id, reason: 'r',
                                active: true, started_at: 1.day.ago)
    end

    def add(path, at, poll: false)
      WatchedRequest.create!(user_activity_watch_id: watch.id, user_id: subject_user.id,
                             company_id: company.id, http_method: 'GET', path: path,
                             is_poll: poll, occurred_at: at)
    end

    it 'calls sustained sub-2s navigation machine-paced' do
      base = 2.hours.ago
      10.times { |i| add("/api/v1/module_#{i}", base + i.seconds) }

      get "/api/platform/user_watches/#{watch.id}/report", headers: auth
      cadence = JSON.parse(response.body)['cadence']

      expect(cadence['median_seconds']).to be < 2
      expect(cadence['assessment']).to match(/Machine-paced/)
    end

    it 'calls varied human timing human-paced and says what that does not prove' do
      base = 2.hours.ago
      [0, 17, 42, 55, 90, 130, 160, 200, 250, 300].each_with_index do |offset, i|
        add("/api/v1/module_#{i}", base + offset.seconds)
      end

      get "/api/platform/user_watches/#{watch.id}/report", headers: auth
      cadence = JSON.parse(response.body)['cadence']

      expect(cadence['median_seconds']).to be > 10
      expect(cadence['assessment']).to match(/Human-paced/)
      expect(cadence['assessment']).to match(/does not rule out/i)
    end

    it 'surfaces the once-opened route tail that signals a product tour' do
      base = 2.hours.ago
      5.times { |i| add('/api/v1/leads', base + (i * 30).seconds) }
      %w[printed_checks journal_entries commission-plans].each_with_index do |r, i|
        add("/api/v1/#{r}", base + (200 + i * 30).seconds)
      end

      get "/api/platform/user_watches/#{watch.id}/report", headers: auth
      census = JSON.parse(response.body)['route_census']

      expect(census['distinct_routes']).to eq(4)
      expect(census['singleton_count']).to eq(3)
      expect(census['routes'].first['count']).to eq(5)
    end

    it 'excludes background polling from cadence and census' do
      base = 2.hours.ago
      20.times { |i| add('/api/v1/notifications/unread_count', base + (i * 30).seconds, poll: true) }
      add('/api/v1/leads', base)

      get "/api/platform/user_watches/#{watch.id}/report", headers: auth
      body = JSON.parse(response.body)

      expect(body['totals']['background_polls']).to eq(20)
      expect(body['totals']['navigations']).to eq(1)
      expect(body['route_census']['distinct_routes']).to eq(1)
    end
  end

  describe 'timeline' do
    it 'precomputes the gap between consecutive requests' do
      watch = UserActivityWatch.create!(user_id: subject_user.id, company_id: company.id,
                                        created_by_user_id: admin.id, reason: 'r',
                                        active: true, started_at: 1.day.ago)
      base = 1.hour.ago
      [0, 15, 45].each_with_index do |offset, i|
        WatchedRequest.create!(user_activity_watch_id: watch.id, user_id: subject_user.id,
                               company_id: company.id, http_method: 'GET',
                               path: "/api/v1/x#{i}", occurred_at: base + offset.seconds)
      end

      get "/api/platform/user_watches/#{watch.id}/timeline", headers: auth

      gaps = JSON.parse(response.body)['items'].map { |i| i['gap_seconds'] }
      expect(gaps).to eq([nil, 15.0, 30.0])
    end
  end
end
