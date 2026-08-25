# frozen_string_literal: true

require 'rails_helper'

# The platform operator's view: who is on a tenant site right now, and who has
# just left. Cross-tenant on purpose — that span is the whole value.
RSpec.describe 'Api::Admin::LiveVisitors', type: :request do
  let(:company_a) { Company.create!(name: "A-#{SecureRandom.hex(3)}") }
  let(:company_b) { Company.create!(name: "B-#{SecureRandom.hex(3)}") }

  let(:admin) do
    User.create!(email: "pa-#{SecureRandom.hex(3)}@example.com", first_name: 'P', last_name: 'A',
                 password: 'Pass1234!', company_id: company_a.id, role: 'platform_admin')
  end
  let(:tenant_user) do
    User.create!(email: "cu-#{SecureRandom.hex(3)}@example.com", first_name: 'C', last_name: 'U',
                 password: 'Pass1234!', company_id: company_a.id, role: 'company_admin')
  end

  def headers_for(user)
    { 'Authorization' => "Bearer #{JsonWebToken.encode(user_id: user.id, company_id: user.company_id)}" }
  end

  def page_for(company)
    site = Marketing::MarketingSiteProvisioner.call(company: company)
    site.website_pages.create!(title: "P-#{SecureRandom.hex(2)}", path: "/p-#{SecureRandom.hex(2)}",
                               page_kind: 'landing', blocks: [])
  end

  def visit_for(company, page, last_seen:, bot: false, converted: false, utm: nil, referrer: nil)
    PageVisit.create!(company_id: company.id, website_page_id: page.id,
                      visitor_token: SecureRandom.hex(6), session_token: SecureRandom.hex(6),
                      is_bot: bot, converted: converted, utm_source: utm, referrer: referrer,
                      first_seen_at: last_seen - 2.minutes, last_seen_at: last_seen)
  end

  def json = JSON.parse(response.body)

  describe 'GET /api/admin/live_visitors' do
    it 'refuses a tenant admin' do
      get '/api/admin/live_visitors', headers: headers_for(tenant_user)

      expect(response).to have_http_status(:forbidden).or have_http_status(:unauthorized)
    end

    it 'shows visitors from every tenant, which is the point' do
      visit_for(company_a, page_for(company_a), last_seen: 5.seconds.ago)
      visit_for(company_b, page_for(company_b), last_seen: 5.seconds.ago)

      get '/api/admin/live_visitors', headers: headers_for(admin)

      expect(response).to have_http_status(:ok)
      expect(json['items'].map { |r| r['company'] }).to include(company_a.name, company_b.name)
    end

    # Three missed heartbeats. Showing someone who closed the tab a minute ago
    # is worse than showing nobody.
    it 'leaves out a visit whose beacon stopped' do
      visit_for(company_a, page_for(company_a), last_seen: 10.minutes.ago)

      get '/api/admin/live_visitors', headers: headers_for(admin)

      expect(json['items']).to be_empty
    end

    it 'leaves out bots, which would otherwise sit there looking like people' do
      visit_for(company_a, page_for(company_a), last_seen: 5.seconds.ago, bot: true)

      get '/api/admin/live_visitors', headers: headers_for(admin)

      expect(json['items']).to be_empty
    end

    it 'names the source the same way the landing page report does' do
      visit_for(company_a, page_for(company_a), last_seen: 5.seconds.ago,
                referrer: 'https://m.facebook.com/')

      get '/api/admin/live_visitors', headers: headers_for(admin)

      expect(json['items'].first['source']).to eq('facebook')
    end

    # The thing a third-party live view cannot do.
    it 'says who a visitor is once they are known' do
      page = page_for(company_a)
      source = Source.find_or_create_by!(name: 'Web') { |s| s.source_type = 'web' }
      lead = Lead.create!(company: company_a, source: source, first_name: 'Dana',
                          last_name: 'Reyes', email: "d-#{SecureRandom.hex(3)}@example.com")
      v = visit_for(company_a, page, last_seen: 5.seconds.ago)
      v.update!(identified_entity: lead, identified_at: Time.current)

      get '/api/admin/live_visitors', headers: headers_for(admin)

      identity = json['items'].first['identity']
      expect(identity['type']).to eq('Lead')
      expect(identity['id']).to eq(lead.id)
      expect(identity['name']).to include('Dana')
    end
  end

  describe 'GET /api/admin/live_visitors/history' do
    # A live view alone means noticing a visitor only if you happen to be
    # looking at the moment they are there.
    it 'shows the ones who have left, and not the ones still here' do
      page = page_for(company_a)
      visit_for(company_a, page, last_seen: 5.seconds.ago)
      gone = visit_for(company_a, page, last_seen: 2.hours.ago)

      get '/api/admin/live_visitors/history', headers: headers_for(admin)

      expect(json['items'].map { |r| r['id'] }).to eq([gone.id])
    end

    it 'can narrow to the ones who converted' do
      page = page_for(company_a)
      visit_for(company_a, page, last_seen: 2.hours.ago)
      converted = visit_for(company_a, page, last_seen: 3.hours.ago, converted: true)

      get '/api/admin/live_visitors/history?converted=true', headers: headers_for(admin)

      expect(json['items'].map { |r| r['id'] }).to eq([converted.id])
    end

    it 'paginates rather than returning everything' do
      page = page_for(company_a)
      3.times { |i| visit_for(company_a, page, last_seen: (i + 2).hours.ago) }

      get '/api/admin/live_visitors/history?per_page=2', headers: headers_for(admin)

      expect(json['items'].size).to eq(2)
      expect(json['meta']['total']).to eq(3)
      expect(json['meta']['total_pages']).to eq(2)
    end

    it 'refuses a tenant admin here too' do
      get '/api/admin/live_visitors/history', headers: headers_for(tenant_user)

      expect(response).to have_http_status(:forbidden).or have_http_status(:unauthorized)
    end
  end

  # Two halves of the same question. Reading them on separate screens means
  # missing the moment a dealer's own staff are in the product while their
  # customer is on their site.
  describe 'app users alongside website visitors' do
    it 'tags each row with which kind it is' do
      visit_for(company_a, page_for(company_a), last_seen: 5.seconds.ago)
      tenant_user.update_columns(last_active_at: 30.seconds.ago, last_active_path: '/crm/leads')

      get '/api/admin/live_visitors', headers: headers_for(admin)

      kinds = json['items'].map { |r| r['kind'] }
      expect(kinds).to include('website_visitor', 'app_user')
    end

    it 'names the user and where they were' do
      tenant_user.update_columns(last_active_at: 30.seconds.ago, last_active_path: '/crm/leads/42')

      get '/api/admin/live_visitors', headers: headers_for(admin)

      row = json['items'].find { |r| r['kind'] == 'app_user' }
      expect(row['identity']['email']).to eq(tenant_user.email)
      expect(row['page_path']).to eq('/crm/leads/42')
      expect(row['company']).to eq(company_a.name)
    end

    # A user reading a deal for four minutes makes no requests at all, so the
    # ninety seconds that suits a beacon would show them leaving and returning.
    it 'keeps a user present for longer than a visitor' do
      tenant_user.update_columns(last_active_at: 3.minutes.ago)

      get '/api/admin/live_visitors', headers: headers_for(admin)

      expect(json['items'].map { |r| r['kind'] }).to include('app_user')
    end

    it 'drops a user who has been idle past the window' do
      tenant_user.update_columns(last_active_at: 30.minutes.ago)

      get '/api/admin/live_visitors', headers: headers_for(admin)

      expect(json['items'].map { |r| r['kind'] }).not_to include('app_user')
    end

    it 'never shows a user who has done nothing since this shipped' do
      tenant_user.update_columns(last_active_at: nil)

      get '/api/admin/live_visitors', headers: headers_for(admin)

      expect(json['items'].map { |r| r['kind'] }).not_to include('app_user')
    end

    it 'lists idle users under history when asked for that kind' do
      tenant_user.update_columns(last_active_at: 2.hours.ago)

      get '/api/admin/live_visitors/history?kind=user', headers: headers_for(admin)

      expect(json['items'].map { |r| r['identity']['email'] }).to eq([tenant_user.email])
    end
  end
end
