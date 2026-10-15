# frozen_string_literal: true

require 'rails_helper'

# The Deal Sheet's delivery address starts as the billing address when the
# deal has none, and the rep can change it there.
RSpec.describe 'Deal Sheet delivery address', type: :request do
  let(:company) { Company.create!(name: "Co-#{SecureRandom.hex(4)}").tap { |c| c.tenant_module_overrides.create!(module_key: 'sales.configurator', is_enabled: true) } }
  let(:mfr) { Manufacturer.create!(name: "Champion #{SecureRandom.hex(3)}", industry_type: 'manufactured_home') }
  let(:factory) { mfr.factories.create!(name: 'Decatur', code: "DEC#{SecureRandom.hex(2)}") }
  let(:book) { CatalogPriceBook.create!(manufacturer: mfr, factory: factory, name: 'Decatur 2026', status: 'published', published_at: 1.day.ago) }
  let(:plan) { CatalogPlan.create!(manufacturer: mfr, factory: factory, series: 'Prime Of Indiana', name: 'Apex') }
  let(:variant) { CatalogPlanVariant.create!(catalog_plan: plan, manufacturer: mfr, model_number: '2856H32P01', width_ft: 28, length_ft: 56) }
  let(:user) { User.create!(email: "rep-#{SecureRandom.hex(4)}@example.com", first_name: 'Rita', last_name: 'Rep', password: 'Pass1234!', company_id: company.id, role: 'company_admin') }
  let(:headers) { { 'Authorization' => "Bearer #{JsonWebToken.encode(user_id: user.id, company_id: company.id)}", 'Content-Type' => 'application/json' } }
  let(:buyer) { company.contacts.create!(first_name: 'Pat', last_name: 'Smith', email: 'pat@example.com', street: '12 Elm St', city: 'Denver', state: 'CO', zip: '80202') }
  let(:path) { "/api/v1/deals/#{deal.id}/home_build" }

  def body = JSON.parse(response.body)

  before do
    CatalogVariantPrice.create!(price_book: book, variant: variant, net_base_price: 80_000)
    company.dealer_catalog_terms.create!(price_update_policy: 'auto_all')
  end

  context 'when the deal has a billing address and no delivery address' do
    let(:deal) do
      company.deals.create!(name: 'Smith Apex', contact_id: buyer.id, billing_street: '9 Oak Ave', billing_city: 'Golden',
                            billing_state: 'CO', billing_zip: '80401')
    end

    it 'starts the sheet with the billing address, which the rep can change' do
      deal.update_columns(delivery_street: nil, delivery_city: nil, delivery_state: nil, delivery_zip: nil)
      post path, headers: headers, params: { variant_id: variant.id }.to_json
      expect(body.dig('build', 'deal_terms')).to include('delivery_street' => '9 Oak Ave', 'delivery_city' => 'Golden',
                                                         'delivery_state' => 'CO', 'delivery_zip' => '80401')

      patch path, headers: headers, params: { deal: { delivery_street: '400 Lake Rd', delivery_city: 'Fort Wayne',
                                                      delivery_state: 'IN', delivery_zip: '46802' } }.to_json
      expect(response).to have_http_status(:ok)
      expect(deal.reload).to have_attributes(delivery_street: '400 Lake Rd', delivery_zip: '46802', delivery_state: 'IN')

      get path, headers: headers
      expect(body.dig('build', 'deal_terms', 'delivery_street')).to eq('400 Lake Rd') # the rep's address stays
    end
  end

  it 'falls back to the buyer\'s address when the deal has no billing address' do
    deal = company.deals.create!(name: 'Smith Apex', contact_id: buyer.id)
    deal.update_columns(billing_street: nil, billing_city: nil, billing_state: nil, billing_zip: nil,
                        delivery_street: nil, delivery_city: nil, delivery_state: nil, delivery_zip: nil)
    Truebuild::DealBuild.start(deal: deal, variant: variant)

    get "/api/v1/deals/#{deal.id}/home_build", headers: headers
    expect(body.dig('build', 'deal_terms')).to include('delivery_street' => '12 Elm St', 'delivery_zip' => '80202')
  end

  it 'keeps a delivery address the deal already has' do
    deal = company.deals.create!(name: 'Smith Apex', contact_id: buyer.id, billing_street: '9 Oak Ave', billing_zip: '80401',
                                 delivery_street: '2809 Cherry Street', delivery_state: 'CO')
    Truebuild::DealBuild.start(deal: deal, variant: variant)

    get "/api/v1/deals/#{deal.id}/home_build", headers: headers
    expect(body.dig('build', 'deal_terms')).to include('delivery_street' => '2809 Cherry Street', 'delivery_zip' => nil)
  end
end
