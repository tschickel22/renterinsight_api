# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'Coaching, adoption and content gaps', type: :request do
  include ActiveJob::TestHelper

  let(:company) { create(:company, use_rbac_system: false) }

  def make_user(role: nil)
    User.create!(email: "co-#{SecureRandom.hex(4)}@example.com", password: 'Password123!', company: company,
                 first_name: 'C', last_name: 'O', status: 'active', role: role)
  end

  def auth(u, company_id: company.id)
    { 'Authorization' => "Bearer #{JsonWebToken.encode(user_id: u.id, company_id: company_id)}" }
  end

  def use!(u, key, at: Time.current)
    GuideEvent.create!(company_id: company.id, user_id: u.id, kind: 'page', feature_key: key, occurred_at: at, created_at: at)
    GuideFeatureUsage.create!(company_id: company.id, user: u, feature_key: key, first_used_at: at, last_used_at: at, use_count: 1)
  end

  before do
    entries = %w[page:/crm page:/contacts page:/deals page:/quotes page:/calendar page:/tasks].map do |k|
      { 'key' => k, 'kind' => 'page', 'title' => k.split('/').last.capitalize, 'route' => k.split(':').last, 'requires' => [] }
    end
    entries << { 'key' => 'report:profit-and-loss', 'kind' => 'report', 'title' => 'Profit & Loss', 'route' => '/accounting/reports/profit-and-loss', 'requires' => [] }
    Knowledge::Snapshot.create!(source: 'frontend', snapshot_at: Time.current, modules_hash: 'x', atlas: { 'entries' => entries })
  end

  describe 'tips' do
    it 'suggests the next learning step and a report to someone busy who never opened one, and forgets dismissed ones' do
      rep = make_user
      %w[page:/crm page:/contacts page:/deals page:/quotes page:/calendar].each { |k| use!(rep, k) }

      get '/api/v1/guide/tips', headers: auth(rep)
      keys = JSON.parse(response.body)['tips'].map { |t| t['key'] }
      expect(keys).to include('next:page:/tasks', 'reports')

      post '/api/v1/guide/tips/dismiss', params: { key: 'reports' }, headers: auth(rep), as: :json
      expect(JSON.parse(response.body)['tips'].map { |t| t['key'] }).not_to include('reports')
    end
  end

  describe 'team view' do
    it 'shows a dealership admin how far each person has got' do
      admin = make_user(role: 'admin')
      rep = make_user
      use!(rep, 'page:/deals')

      get '/api/v1/guide/team', headers: auth(admin)
      person = JSON.parse(response.body)['people'].find { |p| p['id'] == rep.id }
      expect(person).to include('features_used_30d' => 1, 'features_ever' => 1)
      expect(person['path']).to include('done' => 1)
    end

    it 'is for admins only' do
      get '/api/v1/guide/team', headers: auth(make_user)
      expect(response).to have_http_status(:forbidden)
    end
  end

  describe 'platform admin views' do
    let(:platform) { make_user(role: 'platform_admin') }

    it 'does not call add-ons unused until tracking has covered a full month' do
      allow_any_instance_of(ModuleAccessService).to receive(:enabled_modules).and_return(['crm.deals'])
      Knowledge::Snapshot.create!(source: 'frontend', snapshot_at: 1.minute.from_now, modules_hash: 'y',
                                  atlas: { 'entries' => [{ 'key' => 'page:/deals', 'title' => 'Deals', 'route' => '/deals',
                                                           'requires' => [{ 'moduleKey' => 'crm.deals' }] }] })
      rep = make_user
      use!(rep, 'page:/crm', at: 2.days.ago)

      row = Guide::Adoption.new.companies(ids: [company.id]).first
      expect(row[:unused_paid_modules]).to eq([])

      use!(make_user, 'page:/crm', at: 40.days.ago)
      row = Guide::Adoption.new.companies(ids: [company.id]).first
      expect(row[:unused_paid_modules]).to eq(['crm.deals'])
    end

    it 'flags a dealership nobody has used for two weeks as drifting' do
      rep = make_user
      use!(rep, 'page:/deals', at: 20.days.ago)

      get '/api/admin/guide/releases/adoption', headers: auth(platform)
      row = JSON.parse(response.body)['companies'].find { |c| c['id'] == company.id }
      expect(row).to include('drifting' => true, 'active_users_30d' => 1)
    end

    it 'lists unanswered questions, most asked first, and queues a draft article for one' do
      2.times { Knowledge::Search.create!(query: 'How do I do a 1099?', result_count: 0, action_taken: 'assistant') }
      Knowledge::Search.create!(query: 'floorplan payoff', result_count: 0)
      Knowledge::Search.create!(query: 'deals', result_count: 3)

      get '/api/admin/guide/releases/gaps', headers: auth(platform)
      gaps = JSON.parse(response.body)['gaps']
      expect(gaps.first).to include('question' => 'How do I do a 1099?', 'asked' => 2, 'from_assistant' => true)
      expect(gaps.map { |g| g['question'] }).not_to include('deals')

      expect {
        post '/api/admin/guide/releases/gaps', params: { question: 'How do I do a 1099?' }, headers: auth(platform), as: :json
      }.to have_enqueued_job(Guide::DraftReleaseItemJob)
      expect(Knowledge::ChangeQueueItem.find_by(entity_type: 'gap').entity_key).to eq('how do i do a 1099')
    end
  end
end
