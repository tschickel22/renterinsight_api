# frozen_string_literal: true

require 'rails_helper'

# Proves the engine-not-LLM boundary: with the LLM stubbed to nil (no network, no API key),
# the endpoint still returns options whose figures come entirely from the deterministic
# engine. The LLM only ever adds summary/explanation text.
RSpec.describe 'Api::V1 Deal Desk ai_solve', type: :request do
  let(:company) { Company.create!(name: "Co-#{SecureRandom.hex(4)}", industry: 'manufactured_housing') }
  let(:user) do
    User.create!(email: "u-#{SecureRandom.hex(4)}@example.com", first_name: 'T', last_name: 'U',
                 password: 'Pass1234!', company_id: company.id, role: 'platform_admin')
  end
  let(:token) { JsonWebToken.encode(user_id: user.id, company_id: company.id) }
  let(:headers) { { 'Authorization' => "Bearer #{token}", 'Content-Type' => 'application/json' } }
  let(:location) { company.locations.create!(name: 'Showroom', timezone: 'America/Denver') }
  let(:account) { company.accounts.create!(name: 'Buyer LLC') }
  let(:unit) do
    company.vehicles.create!(listing_type: 'manufactured_home', status: 'available', year: 2024,
                             make: 'Fleetwood', model: 'Aspire', serial_number: "SN-#{SecureRandom.hex(4)}",
                             bedrooms: 3, bathrooms: 2.0, sale_price: 70_000, dealer_cost: 50_000,
                             location_id: location.id, date_in_stock: 30.days.ago)
  end
  let(:deal) { company.deals.create!(name: 'Test Deal', account: account, vehicle: unit, location_id: location.id) }

  before do
    # Force the deterministic path — no Anthropic call. The engine still produces every figure.
    allow_any_instance_of(DealDesk::AiSolveService).to receive(:claude).and_return(nil)
  end

  def ai_solve(body)
    post '/api/v1/deal_desk/scenarios/ai_solve', params: body.to_json, headers: headers
    JSON.parse(response.body)
  end

  it 'returns engine-computed options for a "$650/mo" prompt with no LLM' do
    body = ai_solve(deal_id: deal.id, prompt: 'get them to $650/mo and protect my gross')
    expect(response).to have_http_status(:ok)

    expect(body['summary']).to be_nil # LLM stubbed -> no narration, but numbers still present
    expect(body['options']).to be_an(Array).and be_present
    body['options'].each { |o| expect(o['explanation']).to be_nil } # no LLM text
  end

  it 'matches the deterministic Solver exactly (numbers come from the engine)' do
    body = ai_solve(deal_id: deal.id, prompt: 'get them to $650/mo')
    term_opt = body['options'].find { |o| o['lever'] == 'term' }
    expect(term_opt).to be_present

    base = DealDesk::CompareService.new(company: company, deal: deal).send(:default_base_structure)
               .merge(price: 70_000.0, unit_cost: 50_000.0)
    expected = DealDesk::Solver.new(base).solve_by_term(target_payment: 650.0)
    expect(term_opt['term_months']).to eq(expected[:term_months])
    expect(term_opt['monthly_payment'].to_f).to eq(expected[:monthly_payment].to_f)
  end

  it 'includes dealer_gross for a cost-viewer (platform_admin)' do
    body = ai_solve(deal_id: deal.id, prompt: 'get them to $650/mo')
    expect(body['options'].any? { |o| o.key?('dealer_gross') }).to be(true)
  end

  it '404s for an unknown deal' do
    post '/api/v1/deal_desk/scenarios/ai_solve', params: { deal_id: 0, prompt: 'x' }.to_json, headers: headers
    expect(response).to have_http_status(:not_found)
  end
end
