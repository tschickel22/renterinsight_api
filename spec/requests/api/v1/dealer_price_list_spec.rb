# frozen_string_literal: true

require 'rails_helper'

# Factory Direct could not change upgrade pricing or fix colors on the Deal
# Sheet (backlog E85). A dealer's own prices, costs, names and colors are now
# saved once and used on every deal, and each change to the factory's figures
# goes to the platform admin to apply for everyone, keep for that dealer, or
# turn down.
RSpec.describe 'Dealer price list and colors', type: :request do
  def dealer(name)
    Company.create!(name: "#{name} #{SecureRandom.hex(3)}").tap do |c|
      c.tenant_module_overrides.create!(module_key: 'sales.configurator', is_enabled: true)
      c.dealer_catalog_terms.create!(price_update_policy: 'auto_all')
      c.dealer_markup_rules.create!(scope_type: 'all', markup_type: 'percent', value: 25)
    end
  end

  let(:company) { dealer('Factory Direct') }
  let(:other) { dealer('Other') }
  let(:platform) { Company.create!(name: "Platform #{SecureRandom.hex(3)}") }
  let(:mfr) { Manufacturer.create!(name: "Champion #{SecureRandom.hex(3)}", industry_type: 'manufactured_home') }
  let(:factory) { mfr.factories.create!(name: 'Decatur', code: "DEC#{SecureRandom.hex(2)}") }
  let(:book) { CatalogPriceBook.create!(manufacturer: mfr, factory: factory, name: 'Decatur 2026', status: 'published', published_at: 1.day.ago) }
  let(:plan) { CatalogPlan.create!(manufacturer: mfr, factory: factory, series: 'Prime', name: 'Apex') }
  let(:variant) { CatalogPlanVariant.create!(catalog_plan: plan, manufacturer: mfr, model_number: '2856H32P01', width_ft: 28, length_ft: 56) }
  let(:exterior) { CatalogOptionGroup.create!(manufacturer: mfr, key: 'exterior', name: 'Exterior', selection_type: 'multiple') }
  let(:extras) { CatalogOptionGroup.create!(manufacturer: mfr, key: 'construction', name: 'Construction', selection_type: 'multiple') }

  def option(group, name, cost, color_set: nil)
    CatalogOption.create!(group: group, manufacturer: mfr, key: "#{group.key}--#{name.parameterize}", name: name,
                          kind: color_set ? 'color' : 'upgrade', metadata: color_set ? { 'color_set' => color_set } : {}).tap do |o|
      CatalogOptionPrice.create!(price_book: book, option: o, dealer_cost: cost, is_standard: cost.nil?)
    end
  end

  let!(:weatherwood) { option(exterior, 'Black Weatherwood', nil, color_set: 'Shingles') }
  let!(:dual_black) { option(exterior, 'Dual Black', nil, color_set: 'Shingles') }
  let!(:dishwasher) { option(extras, 'Dishwasher', 340) }
  let!(:base_price) { CatalogVariantPrice.create!(price_book: book, variant: variant, net_base_price: 49_645) }

  def headers_for(co, role = 'company_admin')
    user = User.create!(email: "u-#{SecureRandom.hex(4)}@example.com", first_name: 'T', last_name: 'S', password: 'Pass1234!',
                        company_id: co.id, role: role)
    { 'Authorization' => "Bearer #{JsonWebToken.encode(user_id: user.id, company_id: co.id)}", 'Content-Type' => 'application/json' }
  end
  let(:headers) { headers_for(company) }
  let(:admin) { headers_for(platform, 'platform_admin') }

  def sheet_for(co, h)
    contact = co.contacts.create!(first_name: 'Pat', last_name: 'Smith', email: "pat-#{SecureRandom.hex(3)}@example.com")
    deal = co.deals.create!(name: 'Smith Apex', contact_id: contact.id)
    path = "/api/v1/deals/#{deal.id}/home_build"
    post path, headers: h, params: { variant_id: variant.id }.to_json
    expect(response).to have_http_status(:created)
    path
  end

  def body = JSON.parse(response.body)
  def lines = body.dig('build', 'lines')
  def base_line = lines.find { |l| l['kind'] == 'base' }
  def shingle_names(path, h)
    get "#{path}/options", headers: h
    body['groups'].flat_map { |g| g['options'] }.select { |o| o['color_set'] == 'Shingles' }.map { |o| o['name'] }
  end

  it "prices a dealer's own base cost for them alone until the admin applies it for everyone" do
    path = sheet_for(company, headers)
    other_path = sheet_for(other, headers_for(other))

    post "/api/v1/truebuild_pricing/price_list/remember", headers: headers,
                                                          params: { kind: 'base', price_id: base_price.id, cost: '51000', note: 'Factory bulletin 10/20' }.to_json
    expect(response).to have_http_status(:ok)
    expect(body).to include('factory_cost' => 49_645.0, 'your_cost' => 51_000.0, 'cost_status' => 'Waiting on review')

    # Their open sheet reprices from their price list; nobody else's moves.
    get path, headers: headers
    expect(base_line).to include('unit_cost' => 51_000.0, 'dealer_cost_set' => true)
    get other_path, headers: headers_for(other)
    expect(base_line['unit_cost']).to eq(49_645.0)

    # Typing it again on a Deal Sheet replaces it, never stacks a second one.
    get path, headers: headers
    post "#{path}/remember", headers: headers, params: { line_id: base_line['id'], cost: 51_200 }.to_json
    expect(response).to have_http_status(:ok)
    expect(base_line['unit_cost']).to eq(51_200.0)
    expect(company.catalog_price_requests.where(status: 'open').count).to eq(1)

    request = company.catalog_price_requests.find_by(status: 'open')
    post "/api/admin/catalog_price_requests/#{request.id}/apply", headers: admin, params: {}.to_json
    expect(response).to have_http_status(:ok)
    expect(base_price.reload.net_base_price).to eq(51_200)
    get other_path, headers: headers_for(other)
    expect(base_line['unit_cost']).to eq(51_200.0)
  end

  it "prices a dealer's own surcharge for them alone until the admin applies it to the book's total" do
    base_price.update!(required_adders: [{ 'label' => 'Steel', 'amount' => 1200 }])
    path = sheet_for(company, headers)
    other_path = sheet_for(other, headers_for(other))
    get path, headers: headers
    book_cost = base_line['unit_cost']

    post '/api/v1/truebuild_pricing/price_list/remember', headers: headers,
                                                          params: { kind: 'base', price_id: base_price.id, surcharge: '1800' }.to_json
    expect(response).to have_http_status(:ok)
    expect(body).to include('factory_surcharge' => 1200.0, 'your_surcharge' => 1800.0, 'surcharge_status' => 'Waiting on review')

    get path, headers: headers
    expect(base_line['unit_cost']).to eq(book_cost + 600)
    expect(base_line['base']).to include('surcharge' => 1800.0, 'book_surcharge' => 1800.0, 'dealer_surcharge_set' => true)
    get other_path, headers: headers_for(other)
    expect(base_line['unit_cost']).to eq(book_cost)

    # From the sheet, for every deal: replaces it, never stacks a second one.
    get path, headers: headers
    post "#{path}/remember", headers: headers, params: { line_id: base_line['id'], surcharge: 2000 }.to_json
    expect(response).to have_http_status(:ok)
    expect(base_line['unit_cost']).to eq(book_cost + 800)
    expect(company.catalog_price_requests.where(field: 'surcharge', status: 'open').count).to eq(1)

    request = company.catalog_price_requests.find_by(field: 'surcharge', status: 'open')
    post "/api/admin/catalog_price_requests/#{request.id}/apply", headers: admin, params: {}.to_json
    expect(response).to have_http_status(:ok)
    expect(base_price.reload.total_base_price).to eq(49_645 + 2000)
    get other_path, headers: headers_for(other)
    expect(base_line['unit_cost']).to eq(book_cost + 800)
  end

  it 'keeps a cost for one dealer, or turns it down and puts them back on the book' do
    path = sheet_for(company, headers)
    get "#{path}/options", headers: headers
    post "#{path}/lines", headers: headers, params: { kind: 'option', option_id: dishwasher.id }.to_json
    dish = lines.find { |l| l['option_id'] == dishwasher.id }

    # The order form says what the dealer charges now: cost 340 plus their 25%.
    get "#{path}/options", headers: headers
    expect(body['groups'].flat_map { |g| g['options'] }.find { |o| o['id'] == dishwasher.id }).to include('price' => 425.0, 'your_price' => nil)
    get path, headers: headers
    post "#{path}/remember", headers: headers, params: { line_id: dish['id'], cost: 395, price: 425 }.to_json
    dish = lines.find { |l| l['option_id'] == dishwasher.id }
    expect(dish).to include('unit_cost' => 395.0, 'unit_retail' => 425.0)

    request = company.catalog_price_requests.find_by(status: 'open')
    post "/api/admin/catalog_price_requests/#{request.id}/keep", headers: admin, params: {}.to_json
    expect(request.reload.status).to eq('dealer_only')
    expect(dishwasher.prices.first.reload.dealer_cost).to eq(340)
    get path, headers: headers
    expect(lines.find { |l| l['option_id'] == dishwasher.id }['unit_cost']).to eq(395.0)

    post "/api/admin/catalog_price_requests/#{request.id}/dismiss", headers: admin, params: { note: 'Bulletin is for Topeka' }.to_json
    get path, headers: headers
    # Back on the factory cost; their own selling price is theirs and stays.
    expect(lines.find { |l| l['option_id'] == dishwasher.id }).to include('unit_cost' => 340.0, 'unit_retail' => 425.0)
  end

  # Dutch Housing's Topeka book names its finishes as standard choices,
  # "3 Tab Shingles: Black Weatherwood", not color options (deal 446).
  it 'adds a color to a set of named standard choices, and picking either kind replaces the other' do
    named = %w[Black\ Weatherwood Desert\ Tan].map do |color|
      CatalogOption.create!(group: exterior, manufacturer: mfr, key: "3-tab--#{color.parameterize}", name: "3 Tab Shingles: #{color}",
                            kind: 'standard').tap { |o| CatalogOptionPrice.create!(price_book: book, option: o, dealer_cost: 0, is_standard: true) }
    end
    path = sheet_for(company, headers)
    post "#{path}/lines", headers: headers, params: { kind: 'option', option_id: named.first.id }.to_json
    expect(lines.map { |l| l['label'] }).to include('3 Tab Shingles: Black Weatherwood')

    post "#{path}/colors", headers: headers, params: { color_set: '3 Tab Shingles', name: 'Charcoal' }.to_json
    expect(response).to have_http_status(:created)
    shingles = lines.map { |l| l['label'] }.grep(/3 Tab Shingles/)
    expect(shingles).to eq(['3 Tab Shingles: Charcoal'])

    post "#{path}/lines", headers: headers, params: { kind: 'option', option_id: named.last.id }.to_json
    expect(lines.map { |l| l['label'] }.grep(/3 Tab Shingles/)).to eq(['3 Tab Shingles: Desert Tan'])

    # The price list's Colors tab lists the set, and a factory choice in it can be hidden.
    post "/api/v1/truebuild_pricing/colors/#{named.first.id}/hide", headers: headers
    expect(response).to have_http_status(:no_content)
    get '/api/v1/truebuild_pricing/price_list', headers: headers, params: { book_id: book.id, kind: 'color' }
    set = body['sets'].find { |x| x['set'] == '3 Tab Shingles' }
    expect(set['colors'].map { |c| [c['name'], c['hidden']] }).to contain_exactly(['Black Weatherwood', true], ['Desert Tan', false])
    expect(set['yours'].map { |c| c['name'] }).to eq(['Charcoal'])
  end

  it 'splits Black Weatherwood into two colors for this dealer, picks one, and the admin applies it for everyone' do
    path = sheet_for(company, headers)
    other_path = sheet_for(other, headers_for(other))

    post "#{path}/colors", headers: headers, params: { color_set: 'Shingles', name: 'Black', replaces_id: weatherwood.id }.to_json
    expect(response).to have_http_status(:created)
    expect(lines.map { |l| l['label'] }).to include('Shingles: Black')
    post "#{path}/colors", headers: headers, params: { color_set: 'Shingles', name: 'Weatherwood' }.to_json
    build = DealHomeBuild.find(body.dig('build', 'id'))

    expect(shingle_names(path, headers)).to contain_exactly('Black', 'Weatherwood', 'Dual Black')
    expect(shingle_names(other_path, headers_for(other))).to contain_exactly('Black Weatherwood', 'Dual Black')

    # The factory PO and Schedule A name the pick.
    expect(Truebuild::FactoryOrder.colors(build)).to include(hash_including('set' => 'Shingles', 'choice' => 'Weatherwood'))

    # The same color typed again on another sheet is the one already saved.
    second = sheet_for(company, headers)
    post "#{second}/colors", headers: headers, params: { color_set: 'Shingles', name: 'black' }.to_json
    expect(company.dealer_colors.count).to eq(2)

    get '/api/admin/catalog_option_requests?status=open', headers: admin
    expect(body['requests'].map { |r| r['label'] }).to contain_exactly('Add Shingles: Black', 'Add Shingles: Weatherwood',
                                                                        'Remove Shingles: Black Weatherwood')
    body['requests'].each { |r| post "/api/admin/catalog_option_requests/#{r['id']}/apply", headers: admin, params: {}.to_json }

    expect(shingle_names(other_path, headers_for(other))).to contain_exactly('Black', 'Weatherwood', 'Dual Black')
    expect(company.dealer_colors.where(status: 'active').count).to eq(0)
    expect(shingle_names(path, headers)).to contain_exactly('Black', 'Weatherwood', 'Dual Black')
  end

  it "renames an option for the dealer only, and a turned-down color leaves the dealer's list" do
    path = sheet_for(company, headers)
    post "#{path}/lines", headers: headers, params: { kind: 'option', option_id: dishwasher.id }.to_json
    dish = lines.find { |l| l['option_id'] == dishwasher.id }
    post "#{path}/remember", headers: headers, params: { line_id: dish['id'], name: 'Dishwasher (stainless)' }.to_json
    expect(lines.find { |l| l['option_id'] == dishwasher.id }).to include('label' => 'Dishwasher (stainless)', 'book_name' => 'Dishwasher')
    expect(dishwasher.reload.name).to eq('Dishwasher')

    post "#{path}/colors", headers: headers, params: { color_set: 'Shingles', name: 'Driftwood' }.to_json
    req = company.catalog_option_requests.find_by(action: 'add')
    post "/api/admin/catalog_option_requests/#{req.id}/dismiss", headers: admin, params: { note: 'Not offered at Decatur' }.to_json
    expect(response).to have_http_status(:ok)
    expect(shingle_names(sheet_for(company, headers), headers)).not_to include('Driftwood')
  end

  it 'lists a color the book carries once per series once, and hides or renames every copy' do
    # Champion's books file each color again for every series.
    copy = CatalogOption.create!(group: exterior, manufacturer: mfr, key: 'exterior--black-weatherwood-aspire', name: 'Black Weatherwood',
                                 kind: 'color', metadata: { 'color_set' => 'Shingles' })
    CatalogOptionPrice.create!(price_book: book, option: copy, is_standard: true, series: 'Aspire')

    get "/api/v1/truebuild_pricing/price_list?book_id=#{book.id}&kind=color", headers: headers
    shingles = body['sets'].find { |s| s['set'] == 'Shingles' }
    expect(shingles['colors'].map { |c| c['name'] }).to eq(['Black Weatherwood', 'Dual Black'])

    # Hidden from the list it was shown by, every copy leaves the Deal Sheet.
    shown = shingles['colors'].first['id']
    post "/api/v1/truebuild_pricing/colors/#{shown}/hide", headers: headers
    path = sheet_for(company, headers)
    expect(shingle_names(path, headers)).to eq(['Dual Black'])

    req = company.catalog_option_requests.find_by(action: 'hide')
    post "/api/admin/catalog_option_requests/#{req.id}/apply", headers: admin, params: {}.to_json
    expect([weatherwood.reload.status, copy.reload.status]).to eq(%w[discontinued discontinued])

    delete "/api/v1/truebuild_pricing/colors/#{shown}/hide", headers: headers
    expect(response).to have_http_status(:no_content)
  end

  it 'lists the price list by factory book with the dealer figures, and refuses another dealer\'s color' do
    post '/api/v1/truebuild_pricing/price_list/remember', headers: headers,
                                                          params: { kind: 'option', price_id: dishwasher.prices.first.id, price: 450, name: 'Dishwasher SS' }.to_json
    get "/api/v1/truebuild_pricing/price_list?book_id=#{book.id}&kind=option", headers: headers
    expect(body['rows'].first).to include('name' => 'Dishwasher SS', 'book_name' => 'Dishwasher', 'factory_cost' => 340.0, 'your_price' => 450.0)

    post '/api/v1/truebuild_pricing/colors', headers: headers, params: { manufacturer_id: mfr.id, color_set: 'Shingles', name: 'Black' }.to_json
    expect(response).to have_http_status(:created)
    get "/api/v1/truebuild_pricing/price_list?book_id=#{book.id}&kind=color", headers: headers
    shingles = body['sets'].find { |s| s['set'] == 'Shingles' }
    expect(shingles['yours'].map { |c| c['name'] }).to eq(['Black'])

    patch "/api/v1/truebuild_pricing/colors/#{company.dealer_colors.first.id}", headers: headers_for(other), params: { name: 'Mine' }.to_json
    expect(response).to have_http_status(:not_found)
  end
end
