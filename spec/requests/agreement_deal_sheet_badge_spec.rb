# frozen_string_literal: true

require 'rails_helper'

# An agreement made from a deal names the Deal Sheet version it used and says
# when the LIVE sheet has moved on since: a line changed, or another version
# was made LIVE. A reprice that changes nothing does not count.
RSpec.describe 'Agreements and the Deal Sheet version', type: :request do
  let(:company) { Company.create!(name: "Co-#{SecureRandom.hex(4)}").tap { |c| c.tenant_module_overrides.create!(module_key: 'sales.configurator', is_enabled: true) } }
  let(:mfr) { Manufacturer.create!(name: "Champion #{SecureRandom.hex(3)}", industry_type: 'manufactured_home') }
  let(:factory) { mfr.factories.create!(name: 'Decatur', code: "DEC#{SecureRandom.hex(2)}") }
  let(:book) { CatalogPriceBook.create!(manufacturer: mfr, factory: factory, name: 'Decatur 2026', status: 'published', published_at: 1.day.ago) }
  let(:plan) { CatalogPlan.create!(manufacturer: mfr, factory: factory, series: 'Prime', name: 'Apex') }
  let(:variant) { CatalogPlanVariant.create!(catalog_plan: plan, manufacturer: mfr, model_number: '2856H32P01', width_ft: 28, length_ft: 56) }
  let(:headers) do
    user = User.create!(email: "u-#{SecureRandom.hex(4)}@example.com", first_name: 'T', last_name: 'S', password: 'Pass1234!',
                        company_id: company.id, role: 'company_admin')
    { 'Authorization' => "Bearer #{JsonWebToken.encode(user_id: user.id, company_id: company.id)}", 'Content-Type' => 'application/json' }
  end
  let(:buyer) { company.contacts.create!(first_name: 'Pat', last_name: 'Smith', email: 'pat@example.com') }
  let(:deal) { company.deals.create!(name: 'Smith Apex', contact_id: buyer.id) }
  let(:path) { "/api/v1/deals/#{deal.id}/home_build" }

  before do
    CatalogVariantPrice.create!(price_book: book, variant: variant, net_base_price: 49_645)
    company.dealer_catalog_terms.create!(price_update_policy: 'auto_all')
    post path, headers: headers, params: { variant_id: variant.id }.to_json
  end

  def badge(agreement)
    get "/api/v1/agreements/#{agreement.id}", headers: headers
    JSON.parse(response.body).then { |b| b['deal_sheet'] || b.dig('agreement', 'deal_sheet') }
  end

  it 'names the version it was made from and notices when the LIVE sheet moves on' do
    post '/api/v1/agreements', headers: headers, params: { agreement: { title: 'Purchase Agreement', deal_id: deal.id, contact_id: buyer.id } }.to_json
    expect(response).to have_http_status(:created)
    agreement = company.agreements.last
    expect(badge(agreement)).to include('version_name' => 'Version 1', 'live' => true, 'changed' => false)

    post "#{path}/reprice", headers: headers
    expect(badge(agreement)).to include('changed' => false)

    post "#{path}/lines", headers: headers, params: { kind: 'custom', label: 'Skirting', unit_retail: 1200, unit_cost: 800 }.to_json
    expect(badge(agreement)).to include('live' => true, 'changed' => true)
  end
end
