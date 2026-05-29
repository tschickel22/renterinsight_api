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

  it 'does not 500 when the filter references a field invalid for the source type' do
    # Contact audience with a Lead-only field (last_activity_at) → must save, blank estimate
    campaign.campaign_audience.update!(source_type: 'Contact')
    patch "/api/v1/campaigns/#{campaign.id}/audience", headers: headers,
          params: { campaign_audience: { filter_tree: { 'type' => 'and', 'children' => [{ 'field' => 'last_activity_at', 'operator' => 'days_since_greater_than', 'value' => 90 }] } } }.to_json
    expect(response).to have_http_status(:ok)
    expect(campaign.campaign_audience.reload.estimated_count).to eq(0)
  end

  it 'creating an audience from a saved audience adopts its source_type and filters' do
    saved = Audience.create!(company_id: company.id, name: "Saved-#{SecureRandom.hex(3)}", source_type: 'Lead',
                             filter_tree: { 'type' => 'and', 'children' => [{ 'field' => 'last_activity_at', 'operator' => 'days_since_greater_than', 'value' => 30 }] })
    fresh = Campaign.create!(company_id: company.id, created_by_user_id: user.id, name: 'C2',
                             campaign_type: 'drip', from_identity_type: 'User', from_identity_id: user.id, throttle_per_day: 100)
    post "/api/v1/campaigns/#{fresh.id}/audience", headers: headers,
         params: { campaign_audience: { saved_audience_id: saved.id } }.to_json
    expect(response).to have_http_status(:created)
    a = fresh.reload.campaign_audience
    expect(a.source_type).to eq('Lead')
    expect(a.saved_audience_id).to eq(saved.id)
    expect(a.filter_tree['children'].first['field']).to eq('last_activity_at')
  end

  it 'selecting a saved audience adopts its source_type and filters' do
    saved = Audience.create!(company_id: company.id, name: "Saved-#{SecureRandom.hex(3)}", source_type: 'Lead',
                             filter_tree: { 'type' => 'and', 'children' => [{ 'field' => 'last_activity_at', 'operator' => 'days_since_greater_than', 'value' => 30 }] })
    campaign.campaign_audience.update!(source_type: 'Contact')
    patch "/api/v1/campaigns/#{campaign.id}/audience", headers: headers,
          params: { campaign_audience: { saved_audience_id: saved.id } }.to_json
    expect(response).to have_http_status(:ok)
    a = campaign.campaign_audience.reload
    expect(a.source_type).to eq('Lead')          # synced from the saved audience
    expect(a.saved_audience_id).to eq(saved.id)
    expect(a.filter_tree['children'].first['field']).to eq('last_activity_at')
  end
end
