# frozen_string_literal: true

require 'rails_helper'

# The forecast counted only deals in three fixed stages (proposal, negotiation,
# closing), and the Analytics tiles only six, so a dealer's own stages
# ('toured') dropped out. Open now means "not won or lost" in their pipeline.
RSpec.describe 'Deal forecast and metrics with a custom pipeline', type: :request do
  let(:company) { Company.create!(name: "Co-#{SecureRandom.hex(4)}") }
  let(:headers) do
    user = User.create!(email: "u-#{SecureRandom.hex(4)}@example.com", first_name: 'T', last_name: 'S', password: 'Pass1234!',
                        company_id: company.id, role: 'company_admin')
    { 'Authorization' => "Bearer #{JsonWebToken.encode(user_id: user.id, company_id: company.id)}" }
  end

  before do
    Setting.set('Company', company.id, 'pipeline_stages', [
      { 'key' => 'toured', 'label' => 'Toured', 'probability' => 40, 'order' => 1 },
      { 'key' => 'contract', 'label' => 'Contract', 'probability' => 75, 'order' => 2 },
      { 'key' => 'sold', 'label' => 'Sold', 'probability' => 100, 'order' => 3 },
      { 'key' => 'gone', 'label' => 'Gone', 'probability' => 0, 'order' => 4 }
    ])
    soon = 10.days.from_now.to_date
    acct = company.accounts.create!(name: 'Buyer')
    company.deals.create!(name: 'A', stage: 'toured', value: 100_000, probability: 40, expected_close_date: soon, account_id: acct.id)
    company.deals.create!(name: 'B', stage: 'contract', value: 200_000, probability: 75, expected_close_date: soon, account_id: acct.id)
    company.deals.create!(name: 'C', stage: 'sold', value: 50_000, probability: 100, expected_close_date: soon, account_id: acct.id)
    company.deals.create!(name: 'D', stage: 'gone', value: 70_000, probability: 0, expected_close_date: soon, account_id: acct.id)
    company.deals.create!(name: 'E', stage: 'contract', value: 999_000, probability: 75, expected_close_date: soon, account_id: acct.id, deleted_at: Time.current)
  end

  it "forecasts every open deal in the dealer's own stages, skipping deleted ones" do
    get '/api/crm/deals/forecast', params: { view: 'all' }, headers: headers
    expect(response).to have_http_status(:ok)
    body = JSON.parse(response.body)
    expect(body['totalForecast'].to_f).to eq(300_000.0)
    expect(body['weightedForecast'].to_f).to eq(190_000.0)
  end

  it 'counts the same open deals in the Analytics metrics' do
    get '/api/crm/deals/metrics', params: { view: 'all' }, headers: headers
    expect(response).to have_http_status(:ok)
    body = JSON.parse(response.body)
    expect(body.dig('total', 'value').to_f).to eq(300_000.0)
    expect(body.dig('total', 'count')).to eq(2)
    expect(body['byStage']).to eq('toured' => 1, 'contract' => 1)
  end
end
