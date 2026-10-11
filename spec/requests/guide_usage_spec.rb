# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'In-app usage tracking', type: :request do
  let(:company) { create(:company, use_rbac_system: false) }
  let(:user) do
    User.create!(email: "usage-#{SecureRandom.hex(4)}@example.com", password: 'Password123!',
                 company: company, first_name: 'Use', last_name: 'R')
  end
  let(:headers) { { 'Authorization' => "Bearer #{JsonWebToken.encode(user_id: user.id, company_id: company.id)}" } }

  def send_events(events, as: headers)
    post '/api/v1/guide/events', params: { events: events }, headers: as, as: :json
  end

  it 'records events and rolls them up per person and feature' do
    send_events([
      { kind: 'page', feature: 'report:profit-and-loss', route: '/accounting/reports/profit-and-loss' },
      { kind: 'page', feature: 'report:profit-and-loss', route: '/accounting/reports/profit-and-loss' },
      { kind: 'click', feature: 'nav:/reports' }
    ])
    expect(JSON.parse(response.body)['recorded']).to eq(3)

    send_events([{ kind: 'page', feature: 'report:profit-and-loss' }])

    usage = GuideFeatureUsage.find_by!(user: user, feature_key: 'report:profit-and-loss')
    expect(usage.use_count).to eq(3)
    expect(usage.company_id).to eq(company.id)
    expect(GuideEvent.where(user_id: user.id).count).to eq(4)
  end

  it 'drops events that are not a known kind or a plausible key' do
    send_events([
      { kind: 'keystroke', feature: 'page:/deals' },
      { kind: 'page', feature: '<script>' },
      { kind: 'page', feature: '' },
      { kind: 'page', feature: 'page:/deals' }
    ])
    expect(JSON.parse(response.body)['recorded']).to eq(1)
  end

  it 'clamps browser timestamps it cannot trust' do
    send_events([{ kind: 'page', feature: 'page:/deals', at: 3.days.from_now.iso8601 }])
    expect(GuideEvent.last.occurred_at).to be_within(1.minute).of(Time.current)
  end

  it 'does not record a platform admin looking around another company' do
    other = create(:company, use_rbac_system: false)
    admin = User.create!(email: "pa-#{SecureRandom.hex(4)}@example.com", password: 'Password123!',
                         company: other, first_name: 'P', last_name: 'A', role: 'platform_admin')
    as_admin = { 'Authorization' => "Bearer #{JsonWebToken.encode(user_id: admin.id, company_id: company.id)}" }

    send_events([{ kind: 'page', feature: 'page:/deals' }], as: as_admin)
    expect(GuideEvent.count).to eq(0)
  end

  it 'returns the person their own usage' do
    send_events([{ kind: 'page', feature: 'setting:users' }])
    get '/api/v1/guide/usage', headers: headers

    expect(JSON.parse(response.body)['features'].map { |f| f['feature'] }).to eq(['setting:users'])
  end

  it 'prunes raw events after 90 days and keeps the rollup' do
    send_events([{ kind: 'page', feature: 'page:/deals' }])
    GuideEvent.update_all(occurred_at: 91.days.ago)

    Guide::PruneEventsJob.perform_now

    expect(GuideEvent.count).to eq(0)
    expect(GuideFeatureUsage.where(user: user).count).to eq(1)
  end
end
