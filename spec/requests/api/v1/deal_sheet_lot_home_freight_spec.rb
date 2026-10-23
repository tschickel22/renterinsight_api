# frozen_string_literal: true

require 'rails_helper'

# A home already on the lot still has to be hauled to the buyer's homesite, so
# its Deal Sheet prices freight from the lot (not the plant), and a sheet
# without freight can add it back.
RSpec.describe 'Deal Sheet freight on a lot home', type: :request do
  let(:company) { Company.create!(name: "Co-#{SecureRandom.hex(4)}").tap { |c| c.tenant_module_overrides.create!(module_key: 'sales.configurator', is_enabled: true) } }
  let(:mfr) { Manufacturer.create!(name: "Champion #{SecureRandom.hex(3)}", industry_type: 'manufactured_home') }
  let(:factory) { mfr.factories.create!(name: 'Decatur', code: "DEC#{SecureRandom.hex(2)}") }
  let(:book) { CatalogPriceBook.create!(manufacturer: mfr, factory: factory, name: 'Decatur 2026', status: 'published', published_at: 1.day.ago) }
  let(:plan) { CatalogPlan.create!(manufacturer: mfr, factory: factory, series: 'Prime Of Indiana', name: 'Apex') }
  let(:variant) { CatalogPlanVariant.create!(catalog_plan: plan, manufacturer: mfr, model_number: '2856H32P01', width_ft: 28, length_ft: 56) }
  let(:user) { User.create!(email: "rep-#{SecureRandom.hex(4)}@example.com", first_name: 'Rita', last_name: 'Rep', password: 'Pass1234!', company_id: company.id, role: 'company_admin') }
  let(:headers) { { 'Authorization' => "Bearer #{JsonWebToken.encode(user_id: user.id, company_id: company.id)}", 'Content-Type' => 'application/json' } }
  let(:lot_home) do
    company.vehicles.create!(year: 2026, make: 'Champion', model: 'Apex', vin: 'APEXLOT1', status: 'available', is_deleted: false,
                             listing_type: 'manufactured_home', catalog_plan_variant_id: variant.id, stock_number: 'S-9',
                             bedrooms: 3, bathrooms: 2, location_zip: '80202')
  end
  let(:buyer) { company.contacts.create!(first_name: 'Pat', last_name: 'Smith', email: 'pat@example.com') }
  let(:deal) do
    company.deals.create!(name: 'Smith Apex', contact_id: buyer.id, vehicle_id: lot_home.id, delivery_street: '9 Oak Ave', delivery_city: 'Golden',
                          delivery_state: 'CO', delivery_zip: '80401')
  end
  let(:path) { "/api/v1/deals/#{deal.id}/home_build" }

  def body = JSON.parse(response.body)
  def freight_line = body.dig('build', 'lines').find { |l| l['kind'] == 'freight' }

  before do
    CatalogVariantPrice.create!(price_book: book, variant: variant, net_base_price: 80_000)
    company.dealer_catalog_terms.create!(price_update_policy: 'auto_all')
    allow(ZipPoint).to receive(:call).and_return(nil)
    allow(ZipPoint).to receive(:call).with('80202').and_return([39.75, -104.99])
    allow(ZipPoint).to receive(:call).with('80401').and_return([39.75, -105.22])
  end

  it 'prices freight from the lot to the homesite' do
    post path, headers: headers, params: { variant_id: variant.id }.to_json
    expect(response).to have_http_status(:created)
    expect(freight_line).to be_present
    expect(freight_line['retail']).to be > 0
    miles = body.dig('build', 'totals', 'freight_miles')
    expect(miles).to be_between(10, 20) # Denver to Golden, not a plant in Indiana
    expect(body.dig('build', 'totals', 'freight_miles_note')).to include('Your lot (80202)')

    patch path, headers: headers, params: { freight_miles: 40 }.to_json
    expect(body.dig('build', 'totals', 'freight_miles')).to eq(40)
  end

  it 'adds freight back to a sheet that has none' do
    post path, headers: headers, params: { variant_id: variant.id }.to_json
    delete "#{path}/lines/#{freight_line['id']}", headers: headers
    expect(freight_line).to be_nil

    post "#{path}/lines", headers: headers, params: { kind: 'freight' }.to_json
    expect(response).to have_http_status(:created)
    expect(freight_line['retail']).to be > 0

    post "#{path}/lines", headers: headers, params: { kind: 'freight' }.to_json
    expect(body.dig('build', 'lines').count { |l| l['kind'] == 'freight' }).to eq(1)
  end
end
