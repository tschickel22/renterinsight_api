# frozen_string_literal: true

require 'rails_helper'

# The home's surcharge (the book's required adders) can be set for one deal.
# Dealer cost moves by the difference; clearing it goes back to the book.
RSpec.describe 'Deal Sheet surcharge', type: :request do
  let(:company) { Company.create!(name: "Co-#{SecureRandom.hex(4)}").tap { |c| c.tenant_module_overrides.create!(module_key: 'sales.configurator', is_enabled: true) } }
  let(:mfr) { Manufacturer.create!(name: "Champion #{SecureRandom.hex(3)}", industry_type: 'manufactured_home') }
  let(:factory) { mfr.factories.create!(name: 'Decatur', code: "DEC#{SecureRandom.hex(2)}") }
  let(:book) { CatalogPriceBook.create!(manufacturer: mfr, factory: factory, name: 'Decatur 2026', status: 'published', published_at: 1.day.ago) }
  let(:plan) { CatalogPlan.create!(manufacturer: mfr, factory: factory, series: 'Prime Of Indiana', name: 'Apex') }
  let(:variant) { CatalogPlanVariant.create!(catalog_plan: plan, manufacturer: mfr, model_number: '2856H32P01', width_ft: 28, length_ft: 56) }
  let(:user) { User.create!(email: "rep-#{SecureRandom.hex(4)}@example.com", first_name: 'Rita', last_name: 'Rep', password: 'Pass1234!', company_id: company.id, role: 'company_admin') }
  let(:headers) { { 'Authorization' => "Bearer #{JsonWebToken.encode(user_id: user.id, company_id: company.id)}", 'Content-Type' => 'application/json' } }
  let(:buyer) { company.contacts.create!(first_name: 'Pat', last_name: 'Smith', email: 'pat@example.com') }
  let(:deal) { company.deals.create!(name: 'Smith Apex', contact_id: buyer.id) }
  let(:path) { "/api/v1/deals/#{deal.id}/home_build" }

  def body = JSON.parse(response.body)
  def base_line = body.dig('build', 'lines').find { |l| l['kind'] == 'base' }

  before do
    CatalogVariantPrice.create!(price_book: book, variant: variant, net_base_price: 80_000,
                                required_adders: [{ 'label' => 'Steel surcharge', 'amount' => 1500 }])
    company.dealer_catalog_terms.create!(price_update_policy: 'auto_all')
  end

  it 'replaces the book surcharge for this deal and goes back to it when cleared' do
    post path, headers: headers, params: { variant_id: variant.id }.to_json
    expect(base_line['base']).to include('surcharge' => 1500.0, 'book_surcharge' => 1500.0)
    book_cost = base_line['unit_cost'].to_f
    expect(base_line['set_surcharge']).to be(false)

    patch "#{path}/lines/#{base_line['id']}", headers: headers, params: { surcharge: 2750 }.to_json
    expect(response).to have_http_status(:ok)
    expect(base_line['base']).to include('surcharge' => 2750.0, 'book_surcharge' => 1500.0)
    expect(base_line['set_surcharge']).to be(true)
    expect(base_line['unit_cost'].to_f).to eq(book_cost + 1250)

    post "#{path}/reprice", headers: headers
    expect(base_line['base']['surcharge']).to eq(2750.0) # kept through repricing

    patch "#{path}/lines/#{base_line['id']}", headers: headers, params: { surcharge: nil }.to_json
    expect(base_line['base']['surcharge']).to eq(1500.0)
    expect(base_line['unit_cost'].to_f).to eq(book_cost)
  end
end
