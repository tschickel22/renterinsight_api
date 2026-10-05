# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'Public TrueBuild', type: :request do
  let(:company) do
    create(:company, name: 'Summit Homes').tap do |c|
      c.tenant_module_overrides.create!(module_key: 'sales.configurator', is_enabled: true) # TrueBuild on the plan
      c.update!(public_inventory_token: SecureRandom.hex(8), public_inventory_settings: { 'public_inventory_enabled' => true })
    end
  end
  let(:token) { company.public_inventory_token }
  # Requests come from the dealer's DealerTide site unless a spec says otherwise (TruebuildReach).
  let!(:site) do
    location = company.locations.create!(name: 'Main Lot')
    Website.create!(company_id: company.id, location_id: location.id, name: 'Summit', slug: "s-#{SecureRandom.hex(4)}", status: 'published')
  end
  let(:mfr) { Manufacturer.create!(name: "Champion #{SecureRandom.hex(3)}", industry_type: 'manufactured_home') }
  let(:factory) { mfr.factories.create!(name: 'Topeka', code: "TOP#{SecureRandom.hex(2)}") }
  let(:plan) { CatalogPlan.create!(manufacturer: mfr, factory: factory, series: 'Aspire', name: 'Belvidere') }
  let(:variant) { CatalogPlanVariant.create!(catalog_plan: plan, manufacturer: mfr, model_number: '2856H32392', width_ft: 28, length_ft: 56, building_code: 'HUD') }
  let(:other_variant) { CatalogPlanVariant.create!(catalog_plan: plan, manufacturer: mfr, model_number: '2876H42180', width_ft: 28, length_ft: 76) }
  let(:book) { CatalogPriceBook.create!(manufacturer: mfr, factory: factory, name: 'Topeka 2026', status: 'published') }
  let(:kitchen) { CatalogOptionGroup.create!(manufacturer: mfr, factory: factory, key: 'kitchen', name: 'Kitchen & Appliances', position: 7) }
  let(:exterior) { CatalogOptionGroup.create!(manufacturer: mfr, factory: factory, key: 'exterior', name: 'Exterior', position: 5) }
  let!(:vehicle) do
    # On order: not built yet, so its finishes can still be chosen.
    Vehicle.create!(company: company, year: 2026, make: 'Champion', model: 'Belvidere', vin: "VIN#{SecureRandom.hex(6).upcase}",
                    status: 'on_order', is_deleted: false, catalog_plan_variant: variant)
  end

  def option(group, name, **price)
    CatalogOption.create!(group: group, manufacturer: mfr, key: "#{group.key}--#{name.parameterize}", name: name,
                          kind: price.delete(:kind) || 'upgrade', metadata: price.delete(:metadata) || {}).tap do |o|
      CatalogOptionPrice.create!(price_book: book, option: o, **price)
    end
  end

  let!(:fridge) { option(kitchen, 'Stainless Fridge', dealer_cost: 1000, suggested_retail: 1550) }
  let!(:dw_only) { option(kitchen, 'Island', dealer_cost: 2000, section_type: 'single') }
  let!(:other_model) { option(kitchen, 'Big Porch', dealer_cost: 900, variant: other_variant) }
  let!(:gas) { option(kitchen, 'Stainless Package - Gas', dealer_cost: 2000) }
  let!(:electric) { option(kitchen, 'Stainless Package - Electric', dealer_cost: 2000) }
  let!(:white) { option(exterior, 'White', kind: 'color', is_standard: true, metadata: { 'color_set' => 'Siding' }) }
  let!(:clay) { option(exterior, 'Clay', kind: 'color', is_standard: true, metadata: { 'color_set' => 'Siding' }) }
  let(:floor_plan) { CatalogOptionGroup.create!(manufacturer: mfr, factory: factory, key: 'floor-plan', name: 'Floor Plan Options', position: 1) }
  let!(:shutter_black) { option(floor_plan, 'Shutters: Black', kind: 'standard', is_standard: true) }
  let!(:siding_olive) { option(floor_plan, 'Siding: Olive', kind: 'standard', is_standard: true) }
  let!(:roofing) { CatalogOptionGroup.create!(manufacturer: mfr, factory: factory, key: 'roofing', name: 'Roofing', position: 4) }
  let!(:shingles) { option(floor_plan, '3 Tab Shingles: Black Weatherwood', kind: 'standard', is_standard: true) }

  before do
    CatalogVariantPrice.create!(price_book: book, variant: variant, net_base_price: 80_000)
    book.standard_features.create!(series: 'Dutch Aspire Sectionals', category: 'Kitchen', name: 'Shaker cabinets')
    book.standard_features.create!(series: 'Dutch Aspire Singles', category: 'Kitchen', name: 'Not for a sectional')
    book.standard_features.create!(series: 'Genesis Homes', category: 'Kitchen', name: 'Not for Aspire')
    # A platform admin released the factory and gave it to this dealer (E64).
    factory.update!(truebuild_released_at: Time.current)
    company.dealer_factories.create!(factory: factory)
    company.dealer_markup_rules.create!(scope_type: 'all', markup_type: 'percent', value: 25)
    # These examples read the full list; the buyer view has its own below.
    company.dealer_catalog_terms.create!(price_display: 'full', buyer_view: 'everything')
    # A lot home opens the designer once its TrueView is drawn; taken as
    # drawn here except where a test says otherwise.
    allow(Truebuild::ModelList).to receive(:trueview_ready).and_wrap_original { |_, ids| ids.to_set }
  end

  it 'gives a buyer the options this home offers, at retail, with colors as one-of sets and no cost anywhere' do
    get "/public/truebuild/homes/#{vehicle.id}", params: { token: token, website_id: site.id }
    expect(response).to have_http_status(:ok)
    body = JSON.parse(response.body)

    expect(body['base_price']).to eq(100_000.0)
    expect(body['base_monthly']).to eq(697) # the dealer's calculator: 90,000 at 6.99% over 240 months
    kitchen_group = body['groups'].find { |g| g['name'] == 'Kitchen & Appliances' }
    expect(kitchen_group['options'].map { |o| [o['name'], o['price']] })
      .to eq([['Stainless Package - Electric', 2500.0], ['Stainless Package - Gas', 2500.0], ['Stainless Fridge', 1250.0]])
    expect(kitchen_group['options'].map { |o| o['family'] }.compact.uniq).to eq(['appliance package'])
    expect(body['standard_features']).to eq([{ 'category' => 'Kitchen', 'items' => ['Shaker cabinets'] }])
    # "Shutters: Black" is a color to choose, filed under Exterior, not an included Floor Plan option.
    sets = body['groups'].find { |g| g['name'] == 'Exterior' }['color_sets'].to_h { |st| [st['name'], st['options'].map { |o| o['name'] }] }
    expect(sets).to eq('Shutters' => ['Black'], 'Siding' => %w[Clay Olive White])
    expect(body['groups'].map { |g| g['name'] }).not_to include('Floor Plan Options')
    expect(body['groups'].find { |g| g['name'] == 'Roofing' }['color_sets']).to match([a_hash_including('name' => 'Shingles')])
    expect(response.body).not_to match(/cost/i)
    expect(body['media']).to include('photos' => [], 'floor_plans' => [], 'tour_url' => nil)
  end

  it 'offers the vinyl floor colors, listed as standard items, as a Flooring choice' do
    floors = CatalogOptionGroup.create!(manufacturer: mfr, factory: factory, key: 'flooring', name: 'Flooring', position: 6)
    option(floors, 'Thunder (9661)', kind: 'standard', is_standard: true)
    option(floors, 'Nordic White (9662)', kind: 'standard', is_standard: true)
    get "/public/truebuild/homes/#{vehicle.id}", params: { token: token, website_id: site.id }
    group = JSON.parse(response.body)['groups'].find { |g| g['name'] == 'Flooring' }
    expect(group['color_sets']).to eq([{ 'name' => 'Flooring', 'options' => group['color_sets'].first['options'] }])
    expect(group['color_sets'].first['options'].map { |o| o['name'] }).to eq(['Nordic White (9662)', 'Thunder (9661)'])
    expect(group['options']).to eq([])
    expect(Truebuild::Trueview::Buyer.new(company, variant).finish_choices(Truebuild::BuyerCatalog.finish_groups(variant))
                                     .map { |f| f[:surface] }).to include('Flooring')
  end

  it 'shows a tile the price book spells two ways as one chip' do
    tile = CatalogOptionGroup.create!(manufacturer: mfr, factory: factory, key: 'tile', name: 'Backsplash & Tile', position: 9)
    { 'Backsplash' => ['1 Row Ceramic Inhale Gris', '1 Row Inhale Gris (ceramic)', '2 Row Ceramic Subway Catch Ice',
                       '2 Rows Catch Ice (subway)', '2 Rows Inhale Gris (ceramic)', 'Glass', 'Subway'] }.each do |set, names|
      names.each { |n| option(tile, n, kind: 'color', is_standard: true, metadata: { 'color_set' => set }) }
    end
    get "/public/truebuild/homes/#{vehicle.id}", params: { token: token, website_id: site.id }
    set = JSON.parse(response.body)['groups'].find { |g| g['name'] == 'Backsplash & Tile' }['color_sets'].first
    expect(set['options'].map { |o| o['name'] })
      .to eq(['1 Row Ceramic Inhale Gris', '2 Row Ceramic Subway Catch Ice', '2 Rows Inhale Gris (ceramic)', 'Glass', 'Subway'])
  end

  it 'asks for the cabinet color once, under Cabinets, before anything else' do
    packages = CatalogOptionGroup.create!(manufacturer: mfr, factory: factory, key: 'packages', name: 'Packages', position: 2)
    cabinets = CatalogOptionGroup.create!(manufacturer: mfr, factory: factory, key: 'cabinets', name: 'Cabinets', position: 10)
    %w[Destin\ White Timberwolf].each do |c|
      option(packages, c, kind: 'color', is_standard: true, metadata: { 'color_set' => 'Cabinets' })
      option(cabinets, c, kind: 'color', is_standard: true, metadata: { 'color_set' => 'Cabinets' })
    end
    option(packages, 'Liberty Package', dealer_cost: 500)
    get "/public/truebuild/homes/#{vehicle.id}", params: { token: token, website_id: site.id }
    groups = JSON.parse(response.body)['groups']
    expect(groups.first['name']).to eq('Cabinets')
    expect(groups.first['color_sets']).to match([a_hash_including('name' => 'Cabinets')])
    expect(groups.first['color_sets'].first['options'].map { |o| o['name'] }).to eq(['Destin White', 'Timberwolf'])
    expect(groups.find { |g| g['name'] == 'Packages' }['color_sets']).to eq([])
  end

  it "applies what Claude or an admin decided about options the name rules miss" do
    decide = ->(o, kind, value = nil) { CatalogOptionDecision.create!(manufacturer: mfr, option_key: o.key, kind: kind, value: value) }
    sxs = option(kitchen, 'Side by Side Fridge Upgrade', dealer_cost: 800)
    french = option(kitchen, 'French Door Fridge Upgrade', dealer_cost: 1200)
    ultimate = option(kitchen, 'Chef Kitchen Bundle', dealer_cost: 5000)
    [sxs, french].each { |o| decide.call(o, 'family', 'refrigerator') }
    decide.call(ultimate, 'includes', 'refrigerator')
    decide.call(gas, 'not_family')
    tile = CatalogOptionGroup.create!(manufacturer: mfr, factory: factory, key: 'tile', name: 'Backsplash & Tile', position: 9)
    stacked = option(tile, 'Inhale Gris Stacked 1 Row', kind: 'color', is_standard: true, metadata: { 'color_set' => 'Backsplash' })
    plain = option(tile, '1 Row Ceramic Inhale Gris', kind: 'color', is_standard: true, metadata: { 'color_set' => 'Backsplash' })
    [stacked, plain].each { |o| decide.call(o, 'same_finish', '1 Row Inhale Gris') }
    floors = CatalogOptionGroup.create!(manufacturer: mfr, factory: factory, key: 'flooring', name: 'Flooring', position: 6)
    slate = option(floors, 'Slate Grey LVP', kind: 'standard', is_standard: true)
    decide.call(slate, 'color_choice', 'Vinyl plank')

    get "/public/truebuild/homes/#{vehicle.id}", params: { token: token, website_id: site.id }
    groups = JSON.parse(response.body)['groups']
    kitchen_options = groups.find { |g| g['name'] == 'Kitchen & Appliances' }['options'].index_by { |o| o['name'] }
    expect(kitchen_options.values_at('Side by Side Fridge Upgrade', 'French Door Fridge Upgrade').map { |o| o['family'] }).to eq(%w[refrigerator refrigerator])
    expect(kitchen_options['Chef Kitchen Bundle']).to include('includes' => 'refrigerator')
    expect(kitchen_options['Stainless Package - Gas']['family']).to be_nil
    expect(kitchen_options['Stainless Package - Electric']['family']).to be_nil # a family of one is no choice
    backsplash = groups.find { |g| g['name'] == 'Backsplash & Tile' }['color_sets'].first['options']
    expect(backsplash.map { |o| o['name'] }).to eq(['1 Row Inhale Gris'])
    expect(groups.find { |g| g['name'] == 'Flooring' }['color_sets'].map { |st| [st['name'], st['options'].map { |o| o['name'] }] })
      .to eq([['Vinyl plank', ['Slate Grey LVP']]])
  end

  it 'moves cabinet colors listed only under Packages to Cabinets' do
    packages = CatalogOptionGroup.create!(manufacturer: mfr, factory: factory, key: 'packages', name: 'Packages', position: 2)
    CatalogOptionGroup.create!(manufacturer: mfr, factory: factory, key: 'cabinets', name: 'Cabinets', position: 10)
    option(packages, 'Timberwolf', kind: 'color', is_standard: true, metadata: { 'color_set' => 'Cabinets' })
    get "/public/truebuild/homes/#{vehicle.id}", params: { token: token, website_id: site.id }
    groups = JSON.parse(response.body)['groups']
    expect(groups.first).to include('name' => 'Cabinets')
    expect(groups.first['color_sets'].first['options'].map { |o| o['name'] }).to eq(['Timberwolf'])
    expect(groups.map { |g| g['name'] }).not_to include('Packages')
  end

  it 'shows a family of options in one place, however the price book filed it' do
    tile = CatalogOptionGroup.create!(manufacturer: mfr, factory: factory, key: 'tile', name: 'Backsplash & Tile', position: 9)
    stray = option(tile, 'Black Stainless Steel Package - Gas', dealer_cost: 3000)
    get "/public/truebuild/homes/#{vehicle.id}", params: { token: token, website_id: site.id }
    groups = JSON.parse(response.body)['groups']
    kitchen = groups.find { |g| g['name'] == 'Kitchen & Appliances' }['options']
    expect(kitchen.map { |o| o['id'] }).to include(stray.id)
    expect(kitchen.select { |o| o['family'] == 'appliance package' }.size).to eq(3)
    expect(groups.map { |g| g['name'] }).not_to include('Backsplash & Tile') # nothing else was in it
  end

  it 'hides every price when the dealer does' do
    company.dealer_catalog_terms.first.update!(price_display: 'hidden')
    get "/public/truebuild/homes/#{vehicle.id}", params: { token: token, website_id: site.id }
    body = JSON.parse(response.body)
    expect(body['display']).to include('show_prices' => false)
    expect(body['base_price']).to be_nil
    expect(body['groups'].flat_map { |g| g['options'] }.map { |o| o['price'] }.uniq).to eq([nil])

    post '/public/truebuild/price', params: { token: token, website_id: site.id, variant_id: variant.id, option_ids: [fridge.id] }
    expect(JSON.parse(response.body)).to include('show_prices' => false, 'total' => nil, 'lines' => [])
  end

  it 'shows a monthly estimate but no price when the dealer shows monthly payments only' do
    company.dealer_catalog_terms.first.update!(price_display: 'monthly')
    get "/public/truebuild/homes/#{vehicle.id}", params: { token: token, website_id: site.id }
    body = JSON.parse(response.body)
    expect(body).to include('base_price' => nil, 'base_monthly' => 697)
    expect(body['display']['payment_terms']).to include('down_pct' => 10.0, 'apr' => 6.99, 'years' => 20.0)
    expect(body['display']).to include('show_prices' => false, 'show_monthly' => true)

    post '/public/truebuild/price', params: { token: token, website_id: site.id, variant_id: variant.id, option_ids: [fridge.id] }
    expect(JSON.parse(response.body)).to include('total' => nil, 'monthly' => 706)

    company.update!(loan_settings: { 'calculator_enabled' => false })
    get "/public/truebuild/homes/#{vehicle.id}", params: { token: token, website_id: site.id }
    expect(JSON.parse(response.body)).to include('base_monthly' => nil)
  end

  it 'prices a selection, dropping options this model does not offer' do
    post '/public/truebuild/price', params: { token: token, website_id: site.id, variant_id: variant.id, option_ids: [fridge.id, other_model.id, dw_only.id] }
    body = JSON.parse(response.body)
    expect(body['total']).to eq(101_250.0)
    expect(body['option_ids']).to eq([fridge.id])
  end

  it 'saves a design, creates the lead through the TrueBuild form, and opens by share link' do
    expect do
      post '/public/truebuild/designs', params: {
        token: token, website_id: site.id, variant_id: variant.id, vehicle_id: vehicle.id, option_ids: [fridge.id, clay.id],
        contact: { first_name: 'Tia', last_name: 'May', email: 'Tia@Example.com', phone: '3035550142' },
        context: { page_url: 'https://summit.mydealertide.com/homes/belvidere-12?x=1', utm_source: 'facebook' }
      }
    end.to change(TruebuildDesign, :count).by(1)
    expect(response).to have_http_status(:created)
    body = JSON.parse(response.body)
    expect(body['price']['total']).to eq(101_250.0)

    design = TruebuildDesign.last
    expect(design).to have_attributes(buyer_email: 'tia@example.com', option_ids: [fridge.id, clay.id], vehicle_id: vehicle.id)
    form = design.intake_submission.intake_form
    expect(form.source.name).to eq('TrueBuild')
    expect(design.intake_submission.data['Message']).to include('Stainless Fridge', '$101,250',
                                                                "https://summit.mydealertide.com/homes/belvidere-12?design=#{design.public_token}")
    # The ad that brought them is kept, but the lead is a TrueBuild lead so its play starts.
    expect(design.lead).to have_attributes(email: 'tia@example.com', source_id: form.source_id, utm_source: 'facebook')

    get "/public/truebuild/designs/#{design.public_token}", params: { token: token, website_id: site.id }
    expect(JSON.parse(response.body)).to include('name' => 'Belvidere (2856H32392)', 'option_ids' => [fridge.id, clay.id])
    expect(design.reload.view_count).to eq(1)
  end

  it 'refuses a save without an email, a home it cannot design, and a wrong token' do
    post '/public/truebuild/designs', params: { token: token, website_id: site.id, variant_id: variant.id, contact: { first_name: 'Tia' } }
    expect(response).to have_http_status(:unprocessable_entity)

    unlinked = Vehicle.create!(company: company, year: 2026, make: 'X', model: 'Y', vin: "VIN#{SecureRandom.hex(6).upcase}",
                               status: 'available', is_deleted: false)
    get "/public/truebuild/homes/#{unlinked.id}", params: { token: token, website_id: site.id }
    expect(response).to have_http_status(:not_found)

    get "/public/truebuild/homes/#{vehicle.id}", params: { token: 'nope' }
    expect(response).to have_http_status(:unauthorized)
  end

  it 'lists the models a dealer offers, with a starting price and photo' do
    variant.update!(media: { 'elevations' => ['https://img/front'] })
    get '/public/truebuild/models', params: { token: token, website_id: site.id }
    models = JSON.parse(response.body)['models']
    expect(models.size).to eq(1)
    expect(models.first).to include('name' => 'Belvidere', 'series' => 'Aspire', 'starting_price' => 100_000.0,
                                    'starting_monthly' => 697, 'image' => 'https://img/front', 'sizes' => ["28' x 56'"])
    expect(models.first['variants'].map { |v| v['id'] }).to eq([variant.id])
    expect(response.body).not_to match(/cost/i)
  end

  it 'shows only the brands, series or TrueView-ready models a site asks for' do
    allow(Truebuild::ModelList).to receive(:trueview_ready).and_call_original
    photo = 'https://s7d9.scene7.com/is/image/championhomes/belvidere-exterior-1'
    variant.update!(media: { 'photos' => [{ 'url' => photo, 'room' => 'exterior' }] })
    names = ->(params) { (get '/public/truebuild/models', params: { token: token, website_id: site.id }.merge(params)) && JSON.parse(response.body)['models'].map { |m| m['name'] } }

    expect(names.call(factory_ids: [factory.id])).to eq(['Belvidere'])
    expect(names.call(factory_ids: [factory.id + 999])).to eq([])
    expect(names.call(series: ['Aspire'])).to eq(['Belvidere'])
    expect(names.call(series: ['Genesis'])).to eq([])
    expect(names.call(trueview_only: true)).to eq([])

    TruebuildRender.create!(catalog_plan_variant: variant, source_url: photo, room: 'exterior', purpose: 'layer', status: 'done',
                            selection: [{ 'surface' => 'Siding', 'value' => 'Clay' }], selection_key: 'k', model_key: 'nb2-lite',
                            provider: 'gemini', model: 'lite', prompt: 'p', layer_url: 'https://b/l.webp',
                            usage: { 'mask_version' => Truebuild::Trueview::Layer::VERSION - 1 })
    Rails.cache.clear
    # Drawn under an older cut still counts: a version bump must not empty the list.
    expect(names.call(trueview_only: true)).to eq(['Belvidere'])
    expect(JSON.parse(response.body)['models'].first['trueview']).to be(true)
    # Only the sizes TrueView is drawn for: another size of the plan drops out.
    other = CatalogPlanVariant.create!(catalog_plan: plan, manufacturer: mfr, model_number: '2852H32392', width_ft: 28, length_ft: 52)
    CatalogVariantPrice.create!(price_book: book, variant: other, net_base_price: 70_000)
    Rails.cache.clear
    variants = (get '/public/truebuild/models', params: { token: token, website_id: site.id, trueview_only: 1 }) && JSON.parse(response.body)['models'].first['variants']
    expect(variants.map { |v| [v['id'], v['trueview']] }).to eq([[variant.id, true]])
    all = (get '/public/truebuild/models', params: { token: token, website_id: site.id }) && JSON.parse(response.body)['models'].first['variants']
    expect(all.map { |v| v['id'] }).to contain_exactly(variant.id, other.id)

    get '/public/truebuild/models', params: { token: token, website_id: site.id, facets: 1 }
    facets = JSON.parse(response.body)['facets']
    # The brand, never the plant: Topeka builds under the manufacturer's name.
    expect(facets['brands']).to eq([{ 'name' => mfr.name, 'factory_ids' => [factory.id], 'models' => 1 }])
    expect(facets['series']).to eq([{ 'name' => 'Aspire', 'factory_ids' => [factory.id], 'models' => 1 }])
    expect(facets['trueview_ready']).to eq(1)
  end

  it 'tells the home page whether the home can be designed, which a built home in stock cannot' do
    get "/public/inventory/#{vehicle.id}", params: { token: token, website_id: site.id, statuses: 'available,on_order' }
    expect(JSON.parse(response.body)['truebuild']).to eq('available' => true)

    vehicle.update!(status: 'available')
    get "/public/inventory/#{vehicle.id}", params: { token: token, website_id: site.id, statuses: 'available,on_order' }
    expect(JSON.parse(response.body)['truebuild']).to eq('available' => false)
    get "/public/truebuild/homes/#{vehicle.id}", params: { token: token, website_id: site.id }
    expect(response).to have_http_status(:not_found)

    # Not built, but its TrueView is not drawn yet: listed like any home.
    vehicle.update!(status: 'on_order')
    allow(Truebuild::ModelList).to receive(:trueview_ready).and_call_original
    Rails.cache.clear
    get "/public/inventory/#{vehicle.id}", params: { token: token, website_id: site.id, statuses: 'available,on_order' }
    expect(JSON.parse(response.body)['truebuild']).to eq('available' => false)
  end

  it 'marks the homes a buyer can design in the listing, and filters to them' do
    built = Vehicle.create!(company: company, year: 2026, make: 'Champion', model: 'Built One', vin: "VIN#{SecureRandom.hex(6).upcase}",
                            status: 'available', is_deleted: false, catalog_plan_variant: variant)
    get '/public/inventory', params: { token: token, website_id: site.id, statuses: 'available,on_order' }
    by_id = JSON.parse(response.body)['items'].index_by { |i| i['id'] }
    expect(by_id[vehicle.id]).to include('designable' => true, 'trueview' => true)
    expect(by_id[built.id]).to include('designable' => false)

    get '/public/inventory', params: { token: token, website_id: site.id, statuses: 'available,on_order', designable: 1 }
    expect(JSON.parse(response.body)['items'].map { |i| i['id'] }).to eq([vehicle.id])
    get '/public/inventory/filters', params: { token: token, website_id: site.id, statuses: 'available,on_order' }
    expect(JSON.parse(response.body)['designable_count']).to eq(1)
  end

  describe "on the dealer's own website (the inventory embed, no website id)" do
    let(:embed) { { token: token, statuses: 'available,on_order' } }

    before { allow_any_instance_of(Website).to receive(:public_url).and_return('https://summit.mydealertide.com') }

    it 'offers no designer without the add-on, and sends the buyer to the home on the DealerTide site' do
      get "/public/inventory/#{vehicle.id}", params: embed
      expect(JSON.parse(response.body)['truebuild'])
        .to eq('available' => false, 'design_url' => "https://summit.mydealertide.com#{Websites::HomeUrl.path_for(vehicle)}")
      get '/public/inventory', params: embed
      expect(JSON.parse(response.body)['items'].find { |i| i['id'] == vehicle.id }).to include('designable' => false)
      get '/public/inventory', params: embed.merge(designable: 1)
      expect(JSON.parse(response.body)['items']).to eq([])
      get '/public/inventory/filters', params: embed
      expect(JSON.parse(response.body)['designable_count']).to eq(0)

      get "/public/truebuild/homes/#{vehicle.id}", params: { token: token }
      expect(response).to have_http_status(:forbidden)
      expect(JSON.parse(response.body)).to eq('error' => 'Design this home on our website', 'design_url' => 'https://summit.mydealertide.com')
      get '/public/truebuild/models', params: { token: token, website_id: 0 } # not one of this dealer's sites
      expect(response).to have_http_status(:forbidden)
    end

    it 'works in the embed with the add-on' do
      company.tenant_module_overrides.create!(module_key: 'sales.truebuild_embed', is_enabled: true)
      get "/public/inventory/#{vehicle.id}", params: embed
      expect(JSON.parse(response.body)['truebuild']).to eq('available' => true)
      get "/public/truebuild/homes/#{vehicle.id}", params: { token: token }
      expect(response).to have_http_status(:ok)
    end

    it "leaves the dealer's DealerTide site as it was" do
      get "/public/inventory/#{vehicle.id}", params: embed.merge(website_id: site.id)
      expect(JSON.parse(response.body)['truebuild']).to eq('available' => true)
      get "/public/truebuild/homes/#{vehicle.id}", params: { token: token, website_id: site.id }
      expect(response).to have_http_status(:ok)
    end
  end

  it "shows the manufacturer's photos and floor plan for a linked home with none of its own" do
    variant.update!(media: { 'photos' => [{ 'url' => 'https://img/kitchen-1', 'room' => 'kitchen' }],
                             'floor_plans' => ['https://img/plan'], 'matterport_url' => 'https://my.matterport.com/show/?m=x' })
    get "/public/inventory/#{vehicle.id}", params: { token: token, website_id: site.id, statuses: 'available,on_order' }
    home = JSON.parse(response.body)['vehicle']
    expect(home).to include('image_urls' => ['https://img/kitchen-1'], 'floor_plan_images' => ['https://img/plan'],
                            'tour_url' => 'https://my.matterport.com/show/?m=x')
  end

  it "shows the factory's own sample on a color chip when a decor sheet has one" do
    CatalogSwatch.create!(manufacturer: mfr, set_name: 'Standard Vinyl Siding', name: 'Clay', hex: '#8c887d', image_url: 'https://b/clay.jpg')
    get "/public/truebuild/models/#{variant.id}", params: { token: token, website_id: site.id }
    siding = JSON.parse(response.body)['groups'].find { |g| g['name'] == 'Exterior' }['color_sets'].find { |c| c['name'] == 'Siding' }
    clay = siding['options'].find { |o| o['name'] == 'Clay' }
    expect(clay).to include('hex' => '#8c887d', 'swatch_url' => 'https://b/clay.jpg')
    expect(siding['options'].find { |o| o['name'] == 'White' }['swatch_url']).to be_nil
  end

  it 'shows no designer for a dealer whose plan does not include TrueBuild' do
    company.tenant_module_overrides.update_all(is_enabled: false)
    get "/public/truebuild/models/#{variant.id}", params: { token: token, website_id: site.id }
    expect(response).to have_http_status(:not_found)
    get '/public/truebuild/models', params: { token: token, website_id: site.id }
    expect(JSON.parse(response.body)['models']).to eq([])
  end

  describe 'buyer view' do
    let(:terms) { company.dealer_catalog_terms.first }
    let(:other) { CatalogOptionGroup.create!(manufacturer: mfr, factory: factory, key: 'other', name: 'Other Options', position: 9) }
    let!(:shirt_rack) { option(other, 'Shirt/Skirt Rack Per Wall', dealer_cost: 75) }
    let!(:fireplace) { option(other, '102 - Std FP', dealer_cost: 900) }
    let!(:fireplace2) { option(other, '104 - Std FP w/ Full Stone', dealer_cost: 1400) }

    def names(group) = JSON.parse(response.body)['groups'].find { |g| g['name'] == group }&.dig('options')&.map { |o| o['name'] }

    it 'curates by default: finishes, pick-one choices buyers care about, and the dealer\'s popular upgrades' do
      terms.update!(buyer_view: 'curated', buyer_featured_option_ids: [fridge.id])
      get "/public/truebuild/models/#{variant.id}", params: { token: token, website_id: site.id }
      expect(names('Kitchen & Appliances')).to contain_exactly('Stainless Package - Electric', 'Stainless Package - Gas', 'Stainless Fridge')
      expect(names('Other Options')).to contain_exactly('102 - Std FP', '104 - Std FP w/ Full Stone')
      expect(JSON.parse(response.body)['groups'].find { |g| g['name'] == 'Exterior' }['color_sets']).not_to be_empty

      # Still offered: the rep can price it at quote time.
      post '/public/truebuild/price', params: { token: token, website_id: site.id, variant_id: variant.id, option_ids: [shirt_rack.id] }.to_json,
                                      headers: { 'Content-Type' => 'application/json' }
      expect(JSON.parse(response.body)['option_ids']).to eq([shirt_rack.id])
    end

    it 'hides groups and options in custom' do
      terms.update!(buyer_view: 'custom', buyer_hidden_groups: ['other options'], buyer_hidden_option_ids: [fridge.id])
      get "/public/truebuild/models/#{variant.id}", params: { token: token, website_id: site.id }
      expect(names('Other Options')).to be_nil
      expect(names('Kitchen & Appliances')).not_to include('Stainless Fridge')
    end
  end

  describe 'TrueView' do
    let(:front) { 'https://s7d9.scene7.com/is/image/championhomes/belvidere-exterior-1' }
    # "None" is the photo as built, never drawn.
    let!(:no_corner) { option(exterior, 'None', kind: 'color', is_standard: true, metadata: { 'color_set' => 'Corner posts' }) }

    around do |ex|
      old = ENV['GEMINI_API_KEY']
      ENV['GEMINI_API_KEY'] = 'test'
      ex.run
    ensure
      ENV['GEMINI_API_KEY'] = old
    end

    before { variant.update!(media: { 'photos' => [{ 'url' => front, 'room' => 'exterior' }, { 'url' => 'https://x/bed.jpg', 'room' => 'bedroom' }] }) }

    def trueview = (get "/public/truebuild/models/#{variant.id}/trueview", params: { token: token, website_id: site.id }) && JSON.parse(response.body)

    # Only a factory run draws; a buyer's visit uses what is there.
    let(:run) { TruebuildFactoryRun.create!(manufacturer: mfr, status: 'running', budget_usd: 5, variant_ids: [variant.id]) }
    def draw! = Truebuild::Trueview::Buyer.new(nil, variant).queue_missing!(run: run)

    it 'draws nothing on a visit; a factory run draws each exterior finish, and the designer shows each as it is drawn' do
      body = nil
      expect { body = trueview }.not_to have_enqueued_job(TruebuildRenderJob)
      expect(body['photos'].first['pending']).to include(clay.id, white.id) # not drawn yet: shown as built
      expect(TruebuildRender.count).to eq(0)

      expect { draw! }.to have_enqueued_job(TruebuildRenderJob).on_queue('low').exactly(5).times
      Rails.cache.clear
      body = trueview
      expect(body['photos'].first).to include('room' => 'exterior', 'url' => "#{front}?wid=1600&fmt=jpeg&qlt=90", 'layers' => {})
      expect(body['photos'].first['pending']).to include(clay.id, white.id)
      expect(body['drawing']).to eq(5)
      expect(TruebuildRender.pluck(:selection).map { |s| s.first.values_at('surface', 'value') })
        .to contain_exactly(%w[Siding Clay], %w[Siding Olive], %w[Siding White], %w[Shutters Black], ['Shingles', 'Black Weatherwood'])

      TruebuildRender.find_by("selection->0->>'value' = 'Clay'")
                     .update!(status: 'done', layer_url: 'https://b/clay.webp', usage: { 'mask_version' => Truebuild::Trueview::Layer::VERSION })
      expect { body = trueview }.not_to have_enqueued_job(TruebuildRenderJob)
      expect(body['photos'].first['layers']).to eq(clay.id.to_s => 'https://b/clay.webp')
      expect(body['photos'].first['pending']).not_to include(clay.id)
      expect(body['drawing']).to eq(4)
    end

    it 'cuts an older drawing again for free instead of paying for a new one' do
      draw!
      clay_row = TruebuildRender.find_by("selection->0->>'value' = 'Clay'")
      clay_row.update!(status: 'done', image_url: 'https://b/clay.png', layer_url: 'https://b/clay-v2.webp', usage: { 'mask_version' => 2 })
      TruebuildRender.where.not(id: clay_row.id).delete_all

      draw!
      recut = TruebuildRender.where("usage ? 'recut_from'").sole
      expect(recut).to have_attributes(image_url: 'https://b/clay.png', status: 'queued')
      expect(recut.usage['recut_from']).to eq(clay_row.id)
    ensure
      ENV.delete('TRUEVIEW_DAILY_LIMIT')
    end

    it 'does not offer a finish whose drawing failed its check, unless it is the last in its set' do
      draw!
      TruebuildRender.find_by("selection->0->>'value' = 'Clay'")
                     .update!(status: 'rejected', layer_url: 'https://b/clay.webp', usage: { 'mask_version' => Truebuild::Trueview::Layer::VERSION })
      TruebuildRender.find_by("selection->0->>'value' = 'Black'")
                     .update!(status: 'rejected', layer_url: 'https://b/black.webp', usage: { 'mask_version' => Truebuild::Trueview::Layer::VERSION })
      get "/public/truebuild/homes/#{vehicle.id}", params: { token: token, website_id: site.id }
      sets = JSON.parse(response.body)['groups'].flat_map { |g| g['color_sets'] }.to_h { |st| [st['name'], st['options'].map { |o| o['name'] }] }
      expect(sets['Siding']).to contain_exactly('White', 'Olive')
      expect(sets['Shutters']).to eq(['Black'])
    end

    it 'does not offer colors for a surface no photo shows, such as shutters on a home without them' do
      draw!
      TruebuildRender.find_by("selection->0->>'surface' = 'Shutters'")
                     .update!(status: 'skipped', usage: { 'mask_version' => Truebuild::Trueview::Layer::VERSION })
      option(floor_plan, 'None', kind: 'color', is_standard: true, metadata: { 'color_set' => 'Shutters' })
      get "/public/truebuild/homes/#{vehicle.id}", params: { token: token, website_id: site.id }
      sets = JSON.parse(response.body)['groups'].flat_map { |g| g['color_sets'] }.map { |st| st['name'] }
      expect(sets).not_to include('Shutters')
      expect(sets).to include('Siding', 'Corner posts')
    end

    it 'still offers a backsplash the kitchen photo does not show: a plain wall is not proof the home has none' do
      tile = CatalogOptionGroup.create!(manufacturer: mfr, factory: factory, key: 'backsplash', name: 'Backsplash & Tile', position: 9)
      gris = option(tile, '1 Row Inhale Gris (ceramic)', kind: 'color', is_standard: true, metadata: { 'color_set' => 'Backsplash' })
      variant.update!(media: { 'photos' => [{ 'url' => 'https://x/kitchen.jpg', 'room' => 'kitchen' }] })
      draw!
      skipped = TruebuildRender.where("selection->0->>'surface' = 'Backsplash'")
                               .update_all(status: 'skipped', usage: { 'mask_version' => Truebuild::Trueview::Layer::VERSION })
      expect(skipped).to be_positive
      Rails.cache.clear
      get "/public/truebuild/homes/#{vehicle.id}", params: { token: token, website_id: site.id }
      backsplash = JSON.parse(response.body)['groups'].flat_map { |g| g['color_sets'] }.find { |st| st['name'] == 'Backsplash' }
      expect(backsplash['options'].map { |o| o['id'] }).to include(gris.id)
    end

    it 'shows the older drawing while it is cut again, and not once the new check rejects it' do
      draw!
      clay_row = TruebuildRender.find_by("selection->0->>'value' = 'Clay'")
      clay_row.update!(status: 'done', image_url: 'https://b/clay.png', layer_url: 'https://b/clay-old.webp', usage: { 'mask_version' => 2, 'outlined' => true })
      draw!
      Rails.cache.clear
      expect(trueview['photos'].first['layers']).to include(clay.id.to_s => 'https://b/clay-old.webp')

      recut = TruebuildRender.where("usage ? 'recut_from'").sole
      recut.update!(status: 'rejected', layer_url: 'https://b/clay-new.webp', usage: recut.usage.merge('mask_version' => Truebuild::Trueview::Layer::VERSION))
      draw!
      Rails.cache.clear
      body = trueview
      expect(body['photos'].first['layers']).not_to have_key(clay.id.to_s)
      # Held back before the larger model tried it: it gets that one try, told what the check found.
      expect(body['photos'].first['pending']).to include(clay.id)
      retry_row = TruebuildRender.where(status: 'queued').where("usage->>'draw_with' = 'nb2'").sole
      expect(retry_row.selection).to eq(recut.selection)
      expect(recut.reload.status).to eq('superseded')
    end

    it 'checks a held-back drawing again, cut again for free, rather than paying for a new one' do
      draw!
      clay_row = TruebuildRender.find_by("selection->0->>'value' = 'Clay'")
      clay_row.update!(status: 'rejected', image_url: 'https://b/clay.png', layer_url: 'https://b/clay.webp', usage: { 'mask_version' => 2 })
      TruebuildRender.where.not(id: clay_row.id).delete_all
      draw!
      expect(TruebuildRender.where("usage ? 'recut_from'").sole.usage['recut_from']).to eq(clay_row.id)
    end

    it 'shows a drawing made before the prompt was reworded, instead of counting it missing' do
      draw!
      clay_row = TruebuildRender.find_by("selection->0->>'value' = 'Clay'")
      clay_row.update!(status: 'done', layer_url: 'https://b/clay.webp', prompt: "#{clay_row.prompt}\nOlder wording.",
                       usage: { 'mask_version' => Truebuild::Trueview::Layer::VERSION })
      Rails.cache.clear
      body = trueview
      expect(body['photos'].first['layers']).to include(clay.id.to_s => 'https://b/clay.webp')
      expect(body['photos'].first['pending']).not_to include(clay.id)
      # And a factory run does not pay for it again.
      queued = TruebuildRender.count
      draw!
      expect(TruebuildRender.count).to eq(queued)
    end

    it 'says which surface each finish paints, so Compare keeps cabinet chips and upgrades in one category' do
      cabinets = CatalogOptionGroup.create!(manufacturer: mfr, factory: factory, key: 'cabinets', name: 'Cabinets', position: 8)
      chip = option(cabinets, 'Destin White', kind: 'color', is_standard: true, metadata: { 'color_set' => 'Cabinets' })
      upgrade = option(cabinets, 'HW Timberwolf IPO Wrapped', dealer_cost: 900)
      option(cabinets, 'HW DestinWhite IPO Wrapped', dealer_cost: 900) # two make the cabinet finish family
      variant.update!(media: { 'photos' => [{ 'url' => 'https://x/kitchen.jpg', 'room' => 'kitchen' }] })
      surfaces = trueview['surfaces']
      expect(surfaces.values_at(chip.id.to_s, upgrade.id.to_s)).to eq(%w[cabinets cabinets])
      expect(surfaces[gas.id.to_s]).to eq('appliances')
    end

    it 'draws a paid cabinet upgrade with its color chip, once, and gives appliance packages a layer' do
      cabinets = CatalogOptionGroup.create!(manufacturer: mfr, factory: factory, key: 'cabinets', name: 'Cabinets', position: 8)
      chip = option(cabinets, 'Destin White', kind: 'color', is_standard: true, metadata: { 'color_set' => 'Cabinets' })
      hw_white = option(cabinets, 'HW DestinWhite IPO Wrapped', dealer_cost: 900)
      option(cabinets, 'HW Timberwolf IPO Wrapped', dealer_cost: 900)
      variant.update!(media: { 'photos' => [{ 'url' => 'https://x/kitchen.jpg', 'room' => 'kitchen' }] })

      plan = Truebuild::Trueview::Buyer.new(company, variant).plan
      by_option = plan.to_h { |p| [p[:option_id], p] }
      expect(by_option[hw_white.id][:key]).to eq(by_option[chip.id][:key])
      expect(by_option[gas.id][:selection]).to eq([{ 'surface' => 'Appliances', 'value' => 'Stainless Package - Gas' }])
      expect(by_option[gas.id][:prompt]).to include('Appliances means the refrigerator')

      # One drawing for the chip and the upgrade.
      expect { draw! }.to have_enqueued_job(TruebuildRenderJob).exactly(plan.map { |p| p[:key] }.uniq.size).times
    end

    it 'leaves picking photos to the factory run too: a visit spends nothing' do
      variant.update!(media: { 'photos' => [{ 'url' => front, 'room' => 'exterior' }, { 'url' => "#{front}-2", 'room' => 'exterior' }] })
      expect { trueview }.not_to have_enqueued_job(TruebuildPhotoPickJob)
      expect(TruebuildRender.count).to eq(0)
    end

    it 'puts a job lost in a restart back on the queue' do
      draw!
      lost = TruebuildRender.first
      lost.update_columns(status: 'running', updated_at: 1.hour.ago)
      expect { trueview }.to have_enqueued_job(TruebuildRenderJob).with(lost.id)
      expect(lost.reload.status).to eq('queued')
    end

    it 'draws nothing when the image key is not set' do
      ENV.delete('GEMINI_API_KEY')
      expect { trueview }.not_to have_enqueued_job(TruebuildRenderJob)
      expect(response).to have_http_status(:ok)
    end
  end
end
