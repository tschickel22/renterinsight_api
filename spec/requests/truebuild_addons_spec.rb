# frozen_string_literal: true

require 'rails_helper'

# A dealer's own packages and fees in TrueBuild: always in the price,
# the buyer's choice, or only on the rep's quote.
RSpec.describe 'TrueBuild dealer add-ons', type: :request do
  let(:company) do
    create(:company, name: 'Summit Homes').tap do |c|
      c.tenant_module_overrides.create!(module_key: 'sales.configurator', is_enabled: true) # TrueBuild on the plan
      # Called with no website id, as the dealer's own site would: needs the embed add-on (E60).
      c.tenant_module_overrides.create!(module_key: TruebuildReach::EMBED_MODULE, is_enabled: true)
      c.update!(public_inventory_token: SecureRandom.hex(8), public_inventory_settings: { 'public_inventory_enabled' => true })
    end
  end
  let(:admin) do
    User.create!(email: "a-#{SecureRandom.hex(4)}@example.com", first_name: 'A', last_name: 'D', password: 'Pass1234!',
                 company_id: company.id, role: 'platform_admin')
  end
  let(:headers) { { 'Authorization' => "Bearer #{JsonWebToken.encode(user_id: admin.id, company_id: company.id)}" } }
  let(:token) { company.public_inventory_token }
  let(:mfr) { Manufacturer.create!(name: "Champion #{SecureRandom.hex(3)}", industry_type: 'manufactured_home') }
  let(:factory) { mfr.factories.create!(name: 'Topeka', code: "TOP#{SecureRandom.hex(2)}") }
  let(:plan) { CatalogPlan.create!(manufacturer: mfr, factory: factory, series: 'Aspire', name: 'Belvidere') }
  let(:variant) { CatalogPlanVariant.create!(catalog_plan: plan, manufacturer: mfr, model_number: '2856H32392', width_ft: 28, length_ft: 56) }
  let(:book) { CatalogPriceBook.create!(manufacturer: mfr, factory: factory, name: 'Topeka 2026', status: 'published', published_at: Time.current) }
  let(:delivery) { FeeTemplate.create!(company: company, name: 'Delivery', fee_type: 'delivery', default_amount: 2500, applies_to: 'manufactured_home') }
  let(:skirting) { company.package_templates.create!(name: 'Vinyl Skirting', default_price: 1800, cost: 900) }
  let(:doc_fee) { FeeTemplate.create!(company: company, name: 'Documentation Fee', fee_type: 'doc', default_amount: 599, taxable: false) }

  before do
    CatalogVariantPrice.create!(price_book: book, variant: variant, net_base_price: 80_000)
    # A platform admin released the factory and gave it to this dealer (E64).
    factory.update!(truebuild_released_at: Time.current)
    company.dealer_factories.create!(factory: factory)
    company.dealer_markup_rules.create!(scope_type: 'all', markup_type: 'percent', value: 25)
    company.dealer_catalog_terms.create!(price_display: 'full')
  end

  def add(source, mode, **extra)
    post '/api/v1/truebuild_pricing/addons', headers: headers,
                                             params: { source_type: source.class.name, source_id: source.id, mode: mode, **extra }
    expect(response).to have_http_status(:created)
    JSON.parse(response.body)
  end

  it 'lets a dealer bring in their packages and fees, and prices a home with them' do
    add(delivery, 'included')
    skirt = add(skirting, 'optional', price_override: 1950)
    add(doc_fee, 'quote_only')

    get '/api/v1/truebuild_pricing/addons', headers: headers
    templates = JSON.parse(response.body)['templates']
    expect(templates.map { |t| t['name'] }).to include('Delivery', 'Vinyl Skirting', 'Documentation Fee')
    expect(templates.find { |t| t['name'] == 'Vinyl Skirting' }['addon_id']).to eq(skirt['id'])

    get "/public/truebuild/models/#{variant.id}", params: { token: token }
    body = JSON.parse(response.body)
    expect(body['addons']).to eq('included' => [{ 'id' => company.truebuild_addons.find_by(source: delivery).id, 'name' => 'Delivery',
                                                  'description' => nil, 'price' => 2500.0 }],
                                 'optional' => [{ 'id' => skirt['id'], 'name' => 'Vinyl Skirting', 'description' => nil, 'price' => 1950.0 }])
    expect(response.body).not_to include('Documentation Fee')
    expect(body['base_price']).to eq(102_500.0) # the opening price already includes delivery

    post '/public/truebuild/price', params: { token: token, variant_id: variant.id }
    expect(JSON.parse(response.body)['total']).to eq(102_500.0) # 100,000 + delivery
    post '/public/truebuild/price', params: { token: token, variant_id: variant.id, addon_ids: [skirt['id'], 999_999] }
    priced = JSON.parse(response.body)
    expect(priced).to include('total' => 104_450.0, 'addon_ids' => [skirt['id']])
    expect(priced['lines'].map { |l| l['label'] }).to eq(['Belvidere (2856H32392)', 'Delivery', 'Vinyl Skirting'])
  end

  it 'saves the chosen add-ons with the design, and the quote gets the quote-only fee' do
    add(delivery, 'included')
    skirt = add(skirting, 'optional')
    add(doc_fee, 'quote_only')

    post '/public/truebuild/designs', params: {
      token: token, variant_id: variant.id, addon_ids: [skirt['id']],
      contact: { first_name: 'Tia', last_name: 'May', email: 'tia@example.com' }
    }
    design = TruebuildDesign.last
    expect(design.metadata['addon_ids']).to eq([skirt['id']])
    expect(design.price_snapshot['total']).to eq(104_300.0)

    contact = Contact.create!(company_id: company.id, first_name: 'Tia', last_name: 'May', email: 'tia@example.com')
    design.update!(contact: contact)
    post "/api/v1/truebuild_designs/#{design.id}/quote", headers: headers
    quote = Quote.find(JSON.parse(response.body)['id'])
    items = quote.items.to_h { |i| [i['description'], i['category']] }
    expect(items).to eq('Belvidere (2856H32392)' => 'home', 'Delivery' => 'fee', 'Vinyl Skirting' => 'package',
                        'Documentation Fee' => 'fee')
    expect(quote.subtotal.to_f).to eq(104_899.0)
  end

  it "refuses another company's templates" do
    other = create(:company)
    theirs = FeeTemplate.create!(company: other, name: 'Theirs', fee_type: 'other', default_amount: 10)
    post '/api/v1/truebuild_pricing/addons', headers: headers, params: { source_type: 'FeeTemplate', source_id: theirs.id, mode: 'included' }
    expect(response).to have_http_status(:unprocessable_entity)
    post '/api/v1/truebuild_pricing/addons', headers: headers, params: { source_type: 'User', source_id: admin.id, mode: 'included' }
    expect(response).to have_http_status(:unprocessable_entity)
  end
end
