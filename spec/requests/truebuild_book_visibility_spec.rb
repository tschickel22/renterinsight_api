# frozen_string_literal: true

require 'rails_helper'

# Dealers can share a price book we load, but factory costs are confidential
# between dealers who have not been given that factory.
RSpec.describe 'TrueBuild price book visibility', type: :request do
  let(:company) do
    create(:company).tap { |c| c.tenant_module_overrides.create!(module_key: 'sales.configurator', is_enabled: true) }
  end
  let(:admin) do
    User.create!(email: "a-#{SecureRandom.hex(4)}@example.com", first_name: 'A', last_name: 'D', password: 'Pass1234!', company_id: company.id, role: 'company_admin')
  end
  let(:platform) do
    User.create!(email: "p-#{SecureRandom.hex(4)}@example.com", first_name: 'P', last_name: 'A', password: 'Pass1234!', company_id: company.id, role: 'platform_admin')
  end
  def auth(user) = { 'Authorization' => "Bearer #{JsonWebToken.encode(user_id: user.id, company_id: company.id)}" }
  def stack(name)
    mfr = Manufacturer.create!(name: "#{name} #{SecureRandom.hex(3)}", industry_type: 'manufactured_home')
    factory = mfr.factories.create!(name: name, code: "F#{SecureRandom.hex(3)}", truebuild_released_at: Time.current)
    plan = CatalogPlan.create!(manufacturer: mfr, factory: factory, series: 'S', name: "#{name} Plan")
    variant = CatalogPlanVariant.create!(catalog_plan: plan, manufacturer: mfr, model_number: "2856H#{rand(10_000)}", width_ft: 28, length_ft: 56, building_code: 'HUD')
    book = CatalogPriceBook.create!(manufacturer: mfr, factory: factory, name: "#{name} book", status: 'published', published_at: Time.current)
    price = CatalogVariantPrice.create!(price_book: book, variant: variant, net_base_price: 80_000)
    { mfr: mfr, factory: factory, variant: variant, book: book, price: price }
  end
  let!(:mine) { stack('Mine') }
  let!(:theirs) { stack('Theirs') }

  before { company.dealer_factories.create!(factory: mine[:factory]) }

  it 'lists only the factories this dealer was given' do
    get '/api/v1/truebuild_pricing', headers: auth(admin)
    expect(response).to have_http_status(:ok)
    expect(response.parsed_body['manufacturers'].map { |m| m['id'] }).to eq([mine[:mfr].id])
  end

  it 'opens the price list of its own book, and refuses another' do
    get '/api/v1/truebuild_pricing/price_list', params: { book_id: mine[:book].id }, headers: auth(admin)
    expect(response.parsed_body['rows'].first['factory_cost']).to eq(80_000.0)

    get '/api/v1/truebuild_pricing/price_list', params: { book_id: theirs[:book].id }, headers: auth(admin)
    expect(response).to have_http_status(:not_found)
    expect(response.body).not_to include('80000')
  end

  it 'refuses every other way into another factory' do
    get '/api/v1/truebuild_pricing/plans', params: { manufacturer_id: theirs[:mfr].id }, headers: auth(admin)
    expect(response.parsed_body['plans']).to eq([])

    get '/api/v1/truebuild_pricing/options', params: { variant_id: theirs[:variant].id }, headers: auth(admin)
    expect(response).to have_http_status(:not_found)

    post '/api/v1/truebuild_pricing/preview', params: { variant_id: theirs[:variant].id }, headers: auth(admin)
    expect(response).to have_http_status(:not_found)

    post '/api/v1/truebuild_pricing/price_list/remember', params: { kind: 'base', price_id: theirs[:price].id, price: 1 }, headers: auth(admin)
    expect(response).to have_http_status(:not_found)

    put '/api/v1/truebuild_pricing/terms', params: { manufacturer_id: theirs[:mfr].id, sale_discount_pct: 1 }, headers: auth(admin)
    expect(response).to have_http_status(:unprocessable_entity)
  end

  it 'shows a dealer with no factories nothing, and the platform team everything' do
    company.dealer_factories.destroy_all
    get '/api/v1/truebuild_pricing', headers: auth(admin)
    expect(response.parsed_body['manufacturers']).to eq([])

    get '/api/v1/truebuild_pricing', headers: auth(platform)
    expect(response.parsed_body['manufacturers'].map { |m| m['id'] }).to include(mine[:mfr].id, theirs[:mfr].id)
  end

  it 'does not tell a dealer about price changes at a factory they were not given' do
    company.dealer_catalog_terms.create!(manufacturer_id: nil, price_update_policy: 'review')
    expect(Truebuild::PriceBookNotifier.subscribers(mine[:book])).to include(company)
    expect(Truebuild::PriceBookNotifier.subscribers(theirs[:book])).not_to include(company)
  end

  describe 'a fee in their own wording' do
    it 'makes one on this company, ready to add' do
      post '/api/v1/truebuild_pricing/fees', params: { name: 'Delivery to homesite', fee_type: 'delivery', default_amount: 1200, company_id: 999 }, headers: auth(admin)
      expect(response).to have_http_status(:created)
      fee = FeeTemplate.find(response.parsed_body['source_id'])
      expect(fee).to have_attributes(company_id: company.id, fee_type: 'delivery', default_amount: 1200)
    end

    it 'refuses the document fee and a repeated name' do
      post '/api/v1/truebuild_pricing/fees', params: { name: 'Doc', fee_type: 'doc' }, headers: auth(admin)
      expect(response).to have_http_status(:unprocessable_entity)

      FeeTemplate.create!(company: company, name: 'Setup', fee_type: 'setup', default_amount: 10)
      post '/api/v1/truebuild_pricing/fees', params: { name: ' setup ', fee_type: 'setup' }, headers: auth(admin)
      expect(response).to have_http_status(:unprocessable_entity)
    end
  end
end
