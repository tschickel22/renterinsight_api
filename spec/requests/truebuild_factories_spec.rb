# frozen_string_literal: true

require 'rails_helper'

# TrueBuild factory readiness and dealer factories (backlog E64): a platform
# admin sees where every factory stands, releases it, and gives released
# factories to dealers. A dealer's buyers see only those.
RSpec.describe 'TrueBuild factories', type: :request do
  let(:company) do
    create(:company, name: 'Summit Homes').tap do |c|
      c.tenant_module_overrides.create!(module_key: 'sales.configurator', is_enabled: true)
      c.update!(public_inventory_token: SecureRandom.hex(8), public_inventory_settings: { 'public_inventory_enabled' => true })
    end
  end
  let!(:site) do
    location = company.locations.create!(name: 'Main Lot')
    Website.create!(company_id: company.id, location_id: location.id, name: 'Summit', slug: "s-#{SecureRandom.hex(4)}", status: 'published')
  end
  let(:admin) do
    User.create!(email: "a-#{SecureRandom.hex(4)}@example.com", first_name: 'Tom', last_name: 'S', password: 'Pass1234!',
                 company_id: company.id, role: 'platform_admin')
  end
  let(:headers) { { 'Authorization' => "Bearer #{JsonWebToken.encode(user_id: admin.id, company_id: company.id)}" } }
  let(:mfr) { Manufacturer.create!(name: "Champion #{SecureRandom.hex(3)}", industry_type: 'manufactured_home') }
  let(:topeka) { mfr.factories.create!(name: 'Topeka', code: "TOP#{SecureRandom.hex(2)}", state: 'KS', latitude: 39.05, longitude: -95.68) }
  let(:lancaster) { mfr.factories.create!(name: 'Lancaster', code: "LAN#{SecureRandom.hex(2)}", state: 'PA', latitude: 40.04, longitude: -76.31) }
  let(:photo) { 'https://s7d9.scene7.com/is/image/championhomes/belvidere-exterior-1' }

  def model(factory, name, number)
    plan = CatalogPlan.create!(manufacturer: mfr, factory: factory, series: 'Aspire', name: name)
    book = CatalogPriceBook.find_by(factory: factory) ||
           CatalogPriceBook.create!(manufacturer: mfr, factory: factory, name: "#{factory.name} 2026", status: 'published', published_at: Time.current)
    CatalogPlanVariant.create!(catalog_plan: plan, manufacturer: mfr, model_number: number, width_ft: 28, length_ft: 56,
                               media: { 'photos' => [{ 'url' => "#{photo}-#{number}", 'room' => 'exterior' }] })
                      .tap { |v| CatalogVariantPrice.create!(price_book: book, variant: v, net_base_price: 80_000) }
  end

  def drawn!(variant, status: 'done')
    TruebuildRender.create!(catalog_plan_variant: variant, source_url: variant.media['photos'][0]['url'], room: 'exterior',
                            purpose: 'layer', status: status, selection: [{ 'surface' => 'Siding', 'value' => 'Clay' }],
                            selection_key: SecureRandom.hex(4), model_key: Truebuild::Trueview::Buyer::MODEL, provider: 'gemini',
                            model: 'lite', prompt: 'p', layer_url: 'https://b/l.webp',
                            usage: { 'mask_version' => Truebuild::Trueview::Layer::VERSION })
    Rails.cache.clear
  end

  def board = (get('/api/admin/truebuild_factories', params: { refresh: 1 }, headers: headers) && JSON.parse(response.body))
  def row(factory) = board['rows'].find { |r| r['id'] == factory.id }

  before do
    company.dealer_markup_rules.create!(scope_type: 'all', markup_type: 'percent', value: 25)
    company.dealer_catalog_terms.create!(price_display: 'full')
  end

  it 'moves a factory from priced to ready as its models are drawn, and to needs review when a drawing is held back' do
    models = 10.times.map { |i| model(topeka, "Plan #{i}", "2856H3#{i}000") }
    expect(row(topeka)).to include('stage' => 'priced', 'models' => 10, 'with_photos' => 10, 'drawn' => 0)

    models.first(9).each { |v| drawn!(v) }
    expect(row(topeka)).to include('stage' => 'ready', 'drawn' => 9, 'share' => 0.9)

    drawn!(models.last, status: 'rejected')
    expect(row(topeka)).to include('stage' => 'needs_review', 'held_back' => 1)
    expect(row(lancaster)).to include('stage' => 'not_started')
  end

  it "shows the book that prices a factory's models, even when it is another plant's package" do
    v = model(topeka, 'Belvidere', '2856H32392')
    plan = CatalogPlan.create!(manufacturer: mfr, factory: lancaster, series: 'Aspire', name: 'Keystone')
    keystone = CatalogPlanVariant.create!(catalog_plan: plan, manufacturer: mfr, model_number: '2856H11111', width_ft: 28, length_ft: 56)
    CatalogVariantPrice.create!(price_book: CatalogPriceBook.find_by(factory: topeka), variant: keystone, net_base_price: 70_000)
    expect(v).to be_present
    expect(row(lancaster)).to include('stage' => 'priced', 'models' => 1)
    expect(row(lancaster)['book']).to include('name' => 'Topeka 2026', 'status' => 'published')
  end

  it 'releases below the bar only with a reason, and shows that it was' do
    v = model(topeka, 'Belvidere', '2856H32392')
    model(topeka, 'Bay Port', '2856H32168')
    drawn!(v)

    post "/api/admin/truebuild_factories/#{topeka.id}/release", headers: headers
    expect(response).to have_http_status(:unprocessable_entity)
    expect(JSON.parse(response.body)['error']).to include('50%')

    post "/api/admin/truebuild_factories/#{topeka.id}/release", params: { note: 'Bay Port photos are renderings.' }, headers: headers
    expect(response).to have_http_status(:ok)
    expect(JSON.parse(response.body)).to include('stage' => 'released')
    expect(JSON.parse(response.body)['released']).to include('by' => 'Tom S', 'note' => 'Bay Port photos are renderings.', 'below_bar' => true)
  end

  it 'gives a dealer only released factories, suggests the near ones, and shows buyers only what the dealer was given' do
    model(topeka, 'Belvidere', '2856H32392')
    model(lancaster, 'Keystone', '2856H11111')
    company.locations.create!(name: 'Denver Showroom', city: 'Denver', state: 'Colorado', zip_code: '80202')
    allow(ZipPoint).to receive(:call).and_return(nil)
    allow(ZipPoint).to receive(:call).with('80202').and_return([39.75, -104.99])
    names = lambda do
      Rails.cache.clear
      get '/public/truebuild/models', params: { token: company.public_inventory_token, website_id: site.id }
      JSON.parse(response.body)['models'].map { |m| m['name'] }
    end

    post '/api/v1/truebuild_factories', params: { factory_id: topeka.id }, headers: headers
    expect(response).to have_http_status(:unprocessable_entity) # not released yet
    expect(names.call).to eq([])

    [topeka, lancaster].each { |f| f.update!(truebuild_released_at: Time.current) }
    get '/api/v1/truebuild_factories', headers: headers
    list = JSON.parse(response.body)
    # Topeka is about 490 miles from Denver, Lancaster about 1,500: neither within 250.
    expect(list['suggestions']).to eq([])
    expect(list['others'].map { |f| f['name'] }).to eq(%w[Lancaster Topeka])

    topeka.update!(latitude: 39.74, longitude: -104.98) # a plant beside the showroom
    get '/api/v1/truebuild_factories', headers: headers
    expect(JSON.parse(response.body)['suggestions']).to contain_exactly(include('name' => 'Topeka', 'miles' => 1))

    # A location with no address uses the company's.
    company.locations.update_all(zip_code: nil, state: nil)
    company.update!(zip_code: '80202')
    get '/api/v1/truebuild_factories', headers: headers
    expect(JSON.parse(response.body)['suggestions']).to contain_exactly(include('name' => 'Topeka', 'miles' => 1))

    post '/api/v1/truebuild_factories', params: { factory_id: topeka.id }, headers: headers
    expect(response).to have_http_status(:created)
    expect(names.call).to eq(['Belvidere'])

    topeka.update!(truebuild_released_at: nil) # unreleased: gone from every dealer at once
    expect(names.call).to eq([])

    topeka.update!(truebuild_released_at: Time.current)
    delete "/api/v1/truebuild_factories/#{topeka.id}", headers: headers
    expect(response).to have_http_status(:no_content)
    expect(names.call).to eq([])
  end

  it 'keeps dealers out' do
    rep = User.create!(email: "r-#{SecureRandom.hex(4)}@example.com", first_name: 'R', last_name: 'P', password: 'Pass1234!',
                       company_id: company.id, role: 'admin')
    rep_headers = { 'Authorization' => "Bearer #{JsonWebToken.encode(user_id: rep.id, company_id: company.id)}" }
    get '/api/v1/truebuild_factories', headers: rep_headers
    expect(response).to have_http_status(:forbidden)
    get '/api/admin/truebuild_factories', headers: rep_headers
    expect(response).to have_http_status(:forbidden)
  end

  it 'names factories that changed stage in the daily notice, once' do
    v = model(topeka, 'Belvidere', '2856H32392')
    Truebuild::FactoryReadiness.stage_changes! # first call records where things stand
    drawn!(v)
    expect(Truebuild::FactoryReadiness.stage_changes!).to eq([{ name: "#{mfr.name} Topeka", from: 'priced', to: 'ready' }])
    expect(Truebuild::FactoryReadiness.stage_changes!).to eq([])
  end
end
