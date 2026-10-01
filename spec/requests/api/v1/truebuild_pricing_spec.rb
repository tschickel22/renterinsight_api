# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'Api::V1::TruebuildPricing', type: :request do
  let(:company) { Company.create!(name: "Dealer #{SecureRandom.hex(3)}") }
  let(:other) { Company.create!(name: "Other #{SecureRandom.hex(3)}") }
  let(:admin) do
    User.create!(email: "a-#{SecureRandom.hex(4)}@example.com", first_name: 'A', last_name: 'D', password: 'Pass1234!',
                 company_id: company.id, role: 'company_admin')
  end
  let(:headers) { { 'Authorization' => "Bearer #{JsonWebToken.encode(user_id: admin.id, company_id: company.id)}" } }
  let(:mfr) { Manufacturer.create!(name: "Champion #{SecureRandom.hex(3)}", industry_type: 'manufactured_home') }
  let(:factory) { mfr.factories.create!(name: 'Topeka', code: "TOP#{SecureRandom.hex(2)}") }
  let(:plan) { CatalogPlan.create!(manufacturer: mfr, factory: factory, series: 'Aspire', name: 'Belvidere') }
  let(:variant) { CatalogPlanVariant.create!(catalog_plan: plan, manufacturer: mfr, model_number: '2856H32392', width_ft: 28, length_ft: 56) }
  let(:book) { CatalogPriceBook.create!(manufacturer: mfr, factory: factory, name: 'Topeka 2026', status: 'published') }
  let(:group) { CatalogOptionGroup.create!(manufacturer: mfr, factory: factory, key: 'cabinets', name: 'Cabinets') }
  let!(:knobs) do
    CatalogOption.create!(group: group, manufacturer: mfr, key: 'cabinets--knobs', name: 'Cabinet Knobs').tap do |o|
      CatalogOptionPrice.create!(price_book: book, option: o, dealer_cost: 65, suggested_retail: 100.75)
    end
  end

  before { CatalogVariantPrice.create!(price_book: book, variant: variant, net_base_price: 57_995) }

  it 'refuses someone without company settings access' do
    rep = User.create!(email: "r-#{SecureRandom.hex(4)}@example.com", first_name: 'R', last_name: 'P', password: 'Pass1234!',
                       company_id: company.id, role: 'sales_rep')
    put '/api/v1/truebuild_pricing/terms', params: { program_discount_pct: 50 },
                                           headers: { 'Authorization' => "Bearer #{JsonWebToken.encode(user_id: rep.id, company_id: company.id)}" }
    expect(response).to have_http_status(:forbidden)
    expect(company.dealer_catalog_terms).to be_empty
  end

  it 'lists manufacturers with published books, their series and groups, and saves terms' do
    get '/api/v1/truebuild_pricing', headers: headers
    body = JSON.parse(response.body)
    expect(body['manufacturers'].map { |m| m['name'] }).to include(mfr.name)
    m = body['manufacturers'].find { |x| x['id'] == mfr.id }
    expect(m['series']).to eq(['Aspire'])
    expect(m['groups'].map { |g| g['name'] }).to eq(['Cabinets'])

    put '/api/v1/truebuild_pricing/terms', headers: headers,
                                           params: { manufacturer_id: mfr.id, program_discount_pct: 2, freight_miles: 150, company_id: other.id }
    expect(response).to have_http_status(:ok)
    terms = company.dealer_catalog_terms.find_by(manufacturer_id: mfr.id)
    expect(terms).to have_attributes(program_discount_pct: 2, freight_miles: 150)
    expect(other.dealer_catalog_terms).to be_empty
  end

  it 'creates, edits and deletes markup rules only for this company' do
    foreign_loc = other.locations.create!(name: 'Elsewhere', timezone: 'UTC')
    post '/api/v1/truebuild_pricing/rules', headers: headers,
                                            params: { scope_type: 'series', manufacturer_id: mfr.id, scope_value: 'Aspire',
                                                      markup_type: 'multiplier', value: 1.3, location_id: foreign_loc.id }
    expect(response).to have_http_status(:created)
    rule = company.dealer_markup_rules.last
    expect(rule.location_id).to be_nil
    expect(JSON.parse(response.body)['scope_label']).to eq("#{mfr.name} Aspire")

    patch "/api/v1/truebuild_pricing/rules/#{rule.id}", headers: headers, params: { value: 1.28 }
    expect(rule.reload.value).to eq(1.28)

    foreign = other.dealer_markup_rules.create!(scope_type: 'all', markup_type: 'multiplier', value: 2)
    delete "/api/v1/truebuild_pricing/rules/#{foreign.id}", headers: headers
    expect(response).to have_http_status(:not_found)
    expect(foreign.reload).to be_persisted

    delete "/api/v1/truebuild_pricing/rules/#{rule.id}", headers: headers
    expect(response).to have_http_status(:no_content)
  end

  it 'lists plans and options for a model, and previews the price' do
    company.dealer_markup_rules.create!(scope_type: 'all', markup_type: 'multiplier', value: 1.3)

    get '/api/v1/truebuild_pricing/plans', headers: headers, params: { manufacturer_id: mfr.id }
    expect(JSON.parse(response.body)['plans'].first['variants'].first['model_number']).to eq('2856H32392')

    get '/api/v1/truebuild_pricing/options', headers: headers, params: { variant_id: variant.id }
    expect(JSON.parse(response.body)['groups'].first['options'].first).to include('name' => 'Cabinet Knobs', 'cost' => 65.0)

    post '/api/v1/truebuild_pricing/preview', headers: headers, params: { variant_id: variant.id, option_ids: [knobs.id] }
    body = JSON.parse(response.body)
    # An "Everything" rule covers options too: 57,995 x 1.3 + 65 x 1.3.
    expect(body['totals']).to include('cost' => 58_060.0, 'retail' => 75_478.0)
    expect(body['lines'].map { |l| l['kind'] }).to eq(%w[base option])
  end

  it 'shows a pending price update, previews at its new prices, and accepts or declines it' do
    company.dealer_markup_rules.create!(scope_type: 'all', markup_type: 'multiplier', value: 1.3)
    newer = CatalogPriceBook.create!(manufacturer: mfr, factory: factory, name: 'Topeka 2027', status: 'in_review')
    CatalogVariantPrice.create!(price_book: newer, variant: variant, net_base_price: 60_000)
    newer.publish!(by: User.new(role: 'platform_admin'))
    Truebuild::PriceBookNotifier.hold_for_review(newer)
    Truebuild::PriceBookNotifier.deliver(newer)
    update = company.dealer_price_book_adoptions.find_by!(price_book: newer)
    foreign = other.dealer_price_book_adoptions.create!(price_book: newer, previous_book: book)

    get '/api/v1/truebuild_pricing', headers: headers
    listed = JSON.parse(response.body)['updates']
    expect(listed.map { |u| u['id'] }).to eq([update.id])
    expect(listed.first).to include('status' => 'pending', 'previous_book_name' => 'Topeka 2026', 'can_decide' => true)

    # Held: cost follows the new book, retail stays at 57,995 x 1.3 until accepted.
    post '/api/v1/truebuild_pricing/preview', headers: headers, params: { variant_id: variant.id }
    expect(JSON.parse(response.body)['totals']).to include('cost' => 60_000.0, 'retail' => 75_393.5)
    post '/api/v1/truebuild_pricing/preview', headers: headers, params: { variant_id: variant.id, update_id: update.id }
    expect(JSON.parse(response.body)['totals']).to include('cost' => 60_000.0, 'retail' => 78_000.0)

    get "/api/v1/truebuild_pricing/updates/#{foreign.id}", headers: headers
    expect(response).to have_http_status(:not_found)

    post "/api/v1/truebuild_pricing/updates/#{update.id}/decline", headers: headers
    expect(update.reload).to have_attributes(status: 'declined', decided_by_id: admin.id)
    post "/api/v1/truebuild_pricing/updates/#{update.id}/accept", headers: headers
    expect(JSON.parse(response.body)).to include('status' => 'adopted', 'summary' => a_hash_including('homes'))
    expect(Truebuild::BookResolver.book_for(company, variant)).to eq(newer)
  end

  describe 'buyer view' do
    it 'saves the view and its lists company-wide, and finds options by name across homes' do
      twin = CatalogOption.create!(group: group, manufacturer: mfr, key: 'cabinets--knobs-2', name: 'Cabinet Knobs ')
      put '/api/v1/truebuild_pricing/terms', headers: headers,
                                             params: { buyer_view: 'custom', buyer_hidden_groups: ['Other Options', ''],
                                                       buyer_hidden_option_ids: [knobs.id.to_s, twin.id.to_s] }
      expect(response).to have_http_status(:ok)
      terms = company.dealer_catalog_terms.find_by(manufacturer_id: nil)
      expect(terms).to have_attributes(buyer_view: 'custom', buyer_hidden_groups: ['Other Options'],
                                       buyer_hidden_option_ids: [knobs.id, twin.id])

      put '/api/v1/truebuild_pricing/terms', headers: headers, params: { buyer_view: 'everyone' }
      expect(response).to have_http_status(:unprocessable_entity)

      get '/api/v1/truebuild_pricing/option_search', headers: headers, params: { q: 'knob', manufacturer_id: mfr.id }
      expect(JSON.parse(response.body)['items']).to eq([{ 'name' => 'Cabinet Knobs', 'group' => 'Cabinets', 'ids' => [knobs.id, twin.id] }])

      get '/api/v1/truebuild_pricing/option_names', headers: headers, params: { ids: [twin.id] }
      expect(JSON.parse(response.body)['items'].first['name']).to eq('Cabinet Knobs')
    end
  end
end
