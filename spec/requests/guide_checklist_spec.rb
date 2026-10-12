# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'Getting started checklist', type: :request do
  let(:company) { create(:company, use_rbac_system: false) }

  def user(role: nil)
    User.create!(email: "gs-#{SecureRandom.hex(4)}@example.com", password: 'Password123!', company: company,
                 first_name: 'G', last_name: 'S', status: 'active', role: role)
  end

  def headers_for(u)
    { 'Authorization' => "Bearer #{JsonWebToken.encode(user_id: u.id, company_id: company.id)}" }
  end

  before do
    Knowledge::Snapshot.create!(
      source: 'frontend', snapshot_at: Time.current, modules_hash: 'x',
      atlas: { 'entries' => %w[page:/crm page:/contacts page:/deals page:/quotes page:/calendar page:/tasks page:/dashboard].map do |k|
        { 'key' => k, 'kind' => 'page', 'title' => k, 'route' => k.split(':').last, 'requires' => [] }
      end }
    )
  end

  it 'ticks learning path items off by real use, not by clicking done' do
    rep = user
    GuideFeatureUsage.create!(company_id: company.id, user: rep, feature_key: 'page:/deals',
                              first_used_at: Time.current, last_used_at: Time.current, use_count: 1)

    get '/api/v1/guide/checklist', headers: headers_for(rep)
    body = JSON.parse(response.body)

    sales = body['paths'].find { |p| p['key'] == 'sales' }
    expect(body['selected_path']).to eq('sales')
    expect(sales['items'].find { |i| i['feature'] == 'page:/deals' }['done']).to eq(true)
    expect(sales['items'].find { |i| i['feature'] == 'page:/crm' }['done']).to eq(false)
    # Only what this person can open: none of the office reports are in the map.
    expect(body['paths'].map { |p| p['key'] }).not_to include('office')
  end

  it 'shows company setup to admins only, checked against real data' do
    admin = user(role: 'admin')
    company.leads.create!(first_name: 'First', last_name: 'Lead', email: 'lead@example.com') rescue nil

    get '/api/v1/guide/checklist', headers: headers_for(admin)
    setup = JSON.parse(response.body)['setup']
    expect(setup.map { |i| i['key'] }).to include('locations', 'team', 'leads')

    get '/api/v1/guide/checklist', headers: headers_for(user)
    expect(JSON.parse(response.body)['setup']).to be_nil
  end

  it 'asks admins to connect the Facebook Page, and to reconnect it once it expires' do
    admin = user(role: 'admin')
    facebook = -> { JSON.parse(response.body)['setup'].find { |i| i['key'] == 'facebook' } }

    get '/api/v1/guide/checklist', headers: headers_for(admin)
    expect(facebook.call).to include('done' => false, 'route' => '/settings?tab=integrations')

    page = company.facebook_integrations.create!(page_id: '123', status: 'active', token_expires_at: 30.days.from_now)
    get '/api/v1/guide/checklist', headers: headers_for(admin)
    expect(facebook.call['done']).to eq(true)

    page.update!(token_expires_at: 1.day.ago)
    get '/api/v1/guide/checklist', headers: headers_for(admin)
    expect(facebook.call['done']).to eq(false)
  end

  it 'remembers the chosen path and a dismissal' do
    rep = user
    patch '/api/v1/guide/checklist', params: { path: 'manager', dismissed: true }, headers: headers_for(rep), as: :json
    body = JSON.parse(response.body)
    expect(body).to include('selected_path' => 'manager', 'dismissed' => true)
  end
end
