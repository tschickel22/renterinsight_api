# frozen_string_literal: true

require 'rails_helper'

# Phase 5 — global search surfaces a deal when a unit/stock# lives in one of its ACTIVE
# Deal Desk scenarios, even if that unit is not the deal's primary unit. No new result type.
RSpec.describe 'Api::V1::Search (Deal Desk integration)', type: :request do
  let(:company) { Company.create!(name: "Co-#{SecureRandom.hex(4)}", industry: 'manufactured_housing') }
  let(:user) do
    User.create!(email: "u-#{SecureRandom.hex(4)}@example.com", first_name: 'T', last_name: 'U',
                 password: 'Pass1234!', company_id: company.id, role: 'platform_admin')
  end
  let(:token) { JsonWebToken.encode(user_id: user.id, company_id: company.id) }
  let(:headers) { { 'Authorization' => "Bearer #{token}" } }
  let(:location) { company.locations.create!(name: 'Showroom', timezone: 'America/Denver') }

  def mh(stock:, **over)
    company.vehicles.create!(listing_type: 'manufactured_home', status: 'available', year: 2024,
                             make: 'Fleetwood', model: 'Aspire', serial_number: "SN-#{SecureRandom.hex(4)}",
                             stock_number: stock, bedrooms: 3, bathrooms: 2.0, sale_price: 70_000,
                             dealer_cost: 50_000, location_id: location.id, date_in_stock: 30.days.ago, **over)
  end

  let(:primary_unit)  { mh(stock: 'PRIMARY-1') }
  let(:scenario_unit) { mh(stock: 'ZQX-9001') }     # the cross-location unit in a scenario
  let(:expired_unit)  { mh(stock: 'EXP-7777') }
  let(:account) { company.accounts.create!(name: 'Buyer LLC') }
  let(:deal) do
    company.deals.create!(name: 'Johnson Purchase', account: account, vehicle: primary_unit, location_id: location.id)
  end

  before do
    # Active scenario referencing a DIFFERENT unit than the deal's primary unit.
    company.deal_desk_scenarios.create!(deal: deal, vehicle: scenario_unit, location_id: location.id,
                                        status: 'active', term_months: 180)
    # Expired scenario referencing yet another unit (must NOT surface via everyday search).
    company.deal_desk_scenarios.create!(deal: deal, vehicle: expired_unit, location_id: location.id,
                                        status: 'expired', term_months: 180)
  end

  def search(q)
    get "/api/v1/search/global?query=#{q}", headers: headers
    JSON.parse(response.body)['results']
  end

  it 'returns the parent deal when a stock# lives in an ACTIVE scenario (not the primary unit)' do
    results = search('ZQX-9001')
    deal_result = results.find { |r| r['type'] == 'deal' && r['id'] == deal.id }

    expect(deal_result).to be_present
    expect(deal_result['desked']).to be(true)
    expect(deal_result['url']).to include("tab=deal_desk")
    expect(deal_result['title']).to eq('Johnson Purchase')
  end

  it 'badges name-matched deals desked when they have active scenarios' do
    deal_result = search('Johnson').find { |r| r['type'] == 'deal' && r['id'] == deal.id }
    expect(deal_result['desked']).to be(true)
  end

  it 'does NOT surface the deal via a stock# that only appears in an EXPIRED scenario' do
    results = search('EXP-7777')
    expect(results.find { |r| r['type'] == 'deal' && r['id'] == deal.id }).to be_nil
  end

  it 'keeps the result type as "deal" (no new SearchResultType)' do
    types = search('ZQX-9001').map { |r| r['type'] }
    expect(types).to include('deal')
    expect(types).not_to include('desked_deal', 'deal_desk', 'scenario')
  end
end
