# frozen_string_literal: true

require 'rails_helper'

# A quote links to a deal through its Deal Sheet, so the deals list says which
# deals have one (the quote form offers only those).
RSpec.describe 'Deals list: which deals have a Deal Sheet', type: :request do
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

  it 'marks the deals that have a LIVE Deal Sheet' do
    CatalogVariantPrice.create!(price_book: book, variant: variant, net_base_price: 49_645)
    company.dealer_catalog_terms.create!(price_update_policy: 'auto_all')
    buyer = company.contacts.create!(first_name: 'Pat', last_name: 'Smith', email: 'pat@example.com')
    with_sheet = company.deals.create!(name: 'Smith Apex', contact_id: buyer.id)
    plain = company.deals.create!(name: 'Smith Lot Home', contact_id: buyer.id)
    post "/api/v1/deals/#{with_sheet.id}/home_build", headers: headers, params: { variant_id: variant.id }.to_json
    expect(response).to have_http_status(:created)

    get '/api/crm/deals', headers: headers, params: { location_id: 'all' }
    rows = JSON.parse(response.body)['deals'].index_by { |d| d['id'] }
    expect(rows[with_sheet.id]['hasDealSheet']).to be(true)
    expect(rows[plain.id]['hasDealSheet']).to be(false)
  end
end
