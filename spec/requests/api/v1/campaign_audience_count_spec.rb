# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'Campaign audience filtered count', type: :request do
  let(:company) { Company.create!(name: "Co-#{SecureRandom.hex(4)}") }
  let(:user) do
    User.create!(email: "u-#{SecureRandom.hex(4)}@example.com", first_name: 'T', last_name: 'U',
                 password: 'Pass1234!', company_id: company.id, role: 'platform_admin')
  end
  let(:token)   { JsonWebToken.encode(user_id: user.id, company_id: company.id) }
  let(:headers) { { 'Authorization' => "Bearer #{token}", 'Content-Type' => 'application/json' } }
  let(:source)  { Source.find_or_create_by!(name: 'Web') { |s| s.source_type = 'web' } }
  let(:campaign) do
    Campaign.create!(company_id: company.id, created_by_user_id: user.id, name: 'C',
                     campaign_type: 'drip', from_identity_type: 'User', from_identity_id: user.id, throttle_per_day: 100)
  end

  before do
    # 1 matching lead + 3 non-matching → filtered count must be 1, total is 4
    Lead.create!(company: company, source: source, first_name: 'Target', last_name: 'X', email: "t-#{SecureRandom.hex(4)}@e.com")
    3.times { Lead.create!(company: company, source: source, first_name: 'Other', last_name: 'Y', email: "o-#{SecureRandom.hex(4)}@e.com") }
    campaign.create_campaign_audience!(
      source_type: 'Lead',
      filter_tree: { 'type' => 'and', 'children' => [{ 'field' => 'first_name', 'operator' => 'contains', 'value' => 'Target' }] }
    )
  end

  it 'recompute returns the filtered count, not the company-wide total' do
    post "/api/v1/campaigns/#{campaign.id}/audience/recompute", headers: headers
    expect(response).to have_http_status(:ok)
    expect(JSON.parse(response.body)['count']).to eq(1)
    expect(campaign.campaign_audience.reload.estimated_count).to eq(1)
  end

  it 'preview returns the filtered count + sample, not the total' do
    post "/api/v1/campaigns/#{campaign.id}/audience/preview", headers: headers
    expect(response).to have_http_status(:ok)
    body = JSON.parse(response.body)
    expect(body['count']).to eq(1)
    expect(body['sample'].size).to eq(1)
    expect(body['filter_evaluation']).to eq('applied')
  end
end
