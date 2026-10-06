# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'Api::V1::DealHomeBuilds', type: :request do
  let(:company) { Company.create!(name: "Co-#{SecureRandom.hex(4)}").tap { |c| c.tenant_module_overrides.create!(module_key: 'sales.configurator', is_enabled: true) } }
  let(:other) { Company.create!(name: "Other-#{SecureRandom.hex(4)}").tap { |c| c.tenant_module_overrides.create!(module_key: 'sales.configurator', is_enabled: true) } }
  let(:mfr) { Manufacturer.create!(name: "Champion #{SecureRandom.hex(3)}", industry_type: 'manufactured_home') }
  let(:factory) { mfr.factories.create!(name: 'Decatur', code: "DEC#{SecureRandom.hex(2)}") }
  let(:book) { CatalogPriceBook.create!(manufacturer: mfr, factory: factory, name: 'Decatur 2026', status: 'published', published_at: 1.day.ago) }
  let(:plan) { CatalogPlan.create!(manufacturer: mfr, factory: factory, series: 'Prime Of Indiana', name: 'Apex') }
  let(:variant) { CatalogPlanVariant.create!(catalog_plan: plan, manufacturer: mfr, model_number: '2856H32P01', width_ft: 28, length_ft: 56) }
  # As production has them: every group multiple-choice, finishes one per color set.
  let(:exterior) { CatalogOptionGroup.create!(manufacturer: mfr, key: 'exterior', name: 'Exterior', selection_type: 'multiple') }
  let(:extras) { CatalogOptionGroup.create!(manufacturer: mfr, key: 'construction', name: 'Construction', selection_type: 'multiple') }

  def option(group, name, cost, standard: false, color_set: nil)
    CatalogOption.create!(group: group, manufacturer: mfr, key: "#{group.key}--#{name.parameterize}", name: name,
                          kind: color_set ? 'color' : 'upgrade', metadata: color_set ? { 'color_set' => color_set } : {}).tap do |o|
      CatalogOptionPrice.create!(price_book: book, option: o, dealer_cost: standard ? nil : cost, is_standard: standard)
    end
  end

  let!(:clay) { option(exterior, 'Clay', nil, standard: true, color_set: 'Siding') }
  let!(:flint) { option(exterior, 'Flint', nil, standard: true, color_set: 'Siding') }
  # Production's other way of writing a set: a standard option named "Set: value".
  let!(:black_shutters) do
    option(exterior, 'Shutters: Black', nil, standard: true).tap { |o| o.update!(kind: 'standard') }
  end
  let!(:wine_shutters) do
    option(exterior, 'Shutters: Wine', nil, standard: true).tap { |o| o.update!(kind: 'standard') }
  end
  let!(:insulation) { option(extras, 'Upgrade Insulation: R38 Roof & R22 Full Blanket Floor Sectional', 1295) }
  let!(:beam) { option(extras, 'Wood Beam On Ceiling - Per LF', 60) }

  def token(company)
    user = User.create!(email: "u-#{SecureRandom.hex(4)}@example.com", first_name: 'T', last_name: 'S', password: 'Pass1234!',
                        company_id: company.id, role: 'company_admin')
    { 'Authorization' => "Bearer #{JsonWebToken.encode(user_id: user.id, company_id: company.id)}", 'Content-Type' => 'application/json' }
  end
  let(:headers) { token(company) }
  let(:buyer) { company.contacts.create!(first_name: 'Pat', last_name: 'Smith', email: 'pat@example.com') }
  let(:deal) { company.deals.create!(name: 'Smith Apex', contact_id: buyer.id) }
  let(:path) { "/api/v1/deals/#{deal.id}/home_build" }

  before do
    CatalogVariantPrice.create!(price_book: book, variant: variant, net_base_price: 49_645)
    company.dealer_catalog_terms.create!(price_update_policy: 'auto_all')
    company.dealer_markup_rules.create!(scope_type: 'all', markup_type: 'percent', value: 25)
  end

  def body = JSON.parse(response.body)
  def line(label) = body.dig('build', 'lines').find { |l| l['label'] == label }

  it 'starts a factory-order build on a deal and prices it through the dealer rules' do
    get path, headers: headers
    expect(body).to include('build' => nil)

    post path, headers: headers, params: { variant_id: variant.id }.to_json
    expect(response).to have_http_status(:created)
    build = body['build']
    expect(build).to include('source' => 'order', 'status' => 'draft')
    # Freight from the stated assumptions until the dealer sets rates: 150 miles x 4.50 x 2 sections
    # + 2 x 150 permits = 1,650; the buyer pays 20% over.
    expect(build['lines'].map { |l| [l['kind'], l['tax_category']] }).to eq([%w[base home], %w[freight delivery]])
    expect(line('Apex (2856H32P01)')).to include('cost' => 49_645.0, 'retail' => 62_056.25)
    expect(line('Freight to homesite')).to include('cost' => 1650.0, 'retail' => 1980.0)
    expect(line('Freight to homesite')['freight']).to include('miles' => 150, 'sections' => 2)
    expect(line('Apex (2856H32P01)')['base']).to include('net_base_price' => 49_645.0, 'program_discount' => 0.0)
    expect(build['model']).to include('factory' => 'Decatur', 'series' => 'Prime Of Indiana', 'section' => 'multi')
    expect(build['totals']).to include('cost' => 51_295.0, 'gross' => 64_036.25, 'retail' => 64_036.25)

    post path, headers: headers, params: { variant_id: variant.id }.to_json
    expect(response).to have_http_status(:unprocessable_entity)
  end

  it 'adds options with quantities, swaps a single-choice finish, and keeps TBD and N/C out of the charge' do
    post path, headers: headers, params: { variant_id: variant.id }.to_json

    post "#{path}/lines", headers: headers, params: { kind: 'option', option_id: clay.id }.to_json
    post "#{path}/lines", headers: headers, params: { kind: 'option', option_id: black_shutters.id }.to_json
    post "#{path}/lines", headers: headers, params: { kind: 'option', option_id: flint.id }.to_json
    post "#{path}/lines", headers: headers, params: { kind: 'option', option_id: wine_shutters.id }.to_json
    expect(body.dig('build', 'lines').map { |l| l['label'] }).to include('Flint', 'Shutters: Wine')
    expect(body.dig('build', 'lines').map { |l| l['label'] }).not_to include('Clay', 'Shutters: Black')
    expect(line('Flint')).to include('standard' => true, 'cost' => 0.0, 'retail' => 0.0)

    post "#{path}/lines", headers: headers, params: { kind: 'option', option_id: beam.id, quantity: 12 }.to_json
    expect(line('Wood Beam On Ceiling - Per LF')).to include('unit' => 'lf', 'quantity' => 12.0, 'cost' => 720.0, 'retail' => 900.0)

    post "#{path}/lines", headers: headers, params: { kind: 'option', option_id: insulation.id }.to_json
    ins = line(insulation.name)
    patch "#{path}/lines/#{ins['id']}", headers: headers, params: { no_charge: true }.to_json
    expect(line(insulation.name)).to include('cost' => 1295.0, 'retail' => 0.0)
    expect(body.dig('build', 'totals')).to include('cost' => 51_295.0 + 720 + 1295, 'retail' => 64_036.25 + 900)

    beam_line = line('Wood Beam On Ceiling - Per LF')
    patch "#{path}/lines/#{beam_line['id']}", headers: headers, params: { tbd: true }.to_json
    expect(body.dig('build', 'totals')).to include('cost' => 51_295.0 + 1295, 'retail' => 64_036.25, 'tbd_count' => 1)
  end

  it 'keeps a price the rep set through repricing, and takes custom lines as typed' do
    post path, headers: headers, params: { variant_id: variant.id }.to_json
    post "#{path}/lines", headers: headers, params: { kind: 'option', option_id: insulation.id }.to_json
    patch "#{path}/lines/#{line(insulation.name)['id']}", headers: headers, params: { unit_retail: 1500 }.to_json
    post "#{path}/reprice", headers: headers
    expect(line(insulation.name)).to include('retail' => 1500.0, 'set_retail' => true)

    post "#{path}/lines", headers: headers,
                          params: { kind: 'custom', label: 'Skirting, vinyl', unit_retail: 2400, unit_cost: 1600, tax_category: 'setup' }.to_json
    expect(line('Skirting, vinyl')).to include('cost' => 1600.0, 'retail' => 2400.0, 'tax_category' => 'setup')
  end

  it "lists the dealer's priced models, limited to the factories they were given" do
    other_plant = mfr.factories.create!(name: 'Topeka', code: "TOP#{SecureRandom.hex(2)}")
    aspire = CatalogPlanVariant.create!(catalog_plan: CatalogPlan.create!(manufacturer: mfr, factory: other_plant, series: 'Aspire', name: 'Bay Port'),
                                        manufacturer: mfr, model_number: '2856H32168', width_ft: 28, length_ft: 56)
    CatalogVariantPrice.create!(price_book: book, variant: aspire, net_base_price: 90_000)

    get "#{path}/models", headers: headers
    expect(body['plans'].map { |p| p['name'] }).to contain_exactly('Apex', 'Bay Port')

    factory.update!(truebuild_released_at: Time.current)
    company.dealer_factories.create!(factory: factory)
    get "#{path}/models", headers: headers
    expect(body['plans'].map { |p| [p['name'], p['variants'].map { |v| v['model_number'] }] }).to eq([['Apex', ['2856H32P01']]])
  end

  it 'takes buyer discounts and miles, and writes the deal: one home line, the extras, the discount columns' do
    company.dealer_catalog_terms.create!(manufacturer: mfr, sale_discount_pct: 10, dealer_savings_pct: 5)
    fee = company.fee_templates.create!(name: 'Set-up and blocking', fee_type: 'setup', default_amount: 2500)
    post path, headers: headers, params: { variant_id: variant.id }.to_json
    expect(body.dig('build', 'discounts')).to include('sale_pct' => 10.0, 'savings_pct' => 5.0)

    patch path, headers: headers, params: { freight_miles: 300 }.to_json
    expect(line('Freight to homesite')).to include('cost' => 3000.0, 'retail' => 3600.0) # 4.50 x 300 x 2 + 300
    expect(body.dig('build', 'freight_miles_set')).to be(true)

    post "#{path}/lines", headers: headers, params: { kind: 'template', template_type: 'FeeTemplate', template_id: fee.id }.to_json
    expect(line('Set-up and blocking')).to include('kind' => 'template', 'retail' => 2500.0, 'tax_category' => 'setup')
    get "#{path}/options", headers: headers
    expect(body['templates'].map { |t| t['name'] }).to include('Set-up and blocking')

    patch path, headers: headers, params: { discounts: { preferred_pct: 2, other_amount: 500 } }.to_json
    t = body.dig('build', 'totals')
    # Gross 62,056.25 + 3,600 + 2,500 = 68,156.25. Savings 5% and sale 10% of the home's 62,056.25;
    # preferred 2% of what is left; other 500.
    expect(t['gross']).to eq(68_156.25)
    expect(t['discounts']).to eq('savings' => 3102.81, 'sale' => 6205.63, 'preferred' => 1176.96, 'other' => 500.0)
    expect(t['retail']).to eq((68_156.25 - 3102.81 - 6205.63 - 1176.96 - 500).round(2))

    products = deal.reload.deal_products.order(:id)
    home = products.find(&:home_line_item?)
    expect(home).to have_attributes(unit_price: 68_156.25 - 2500, cost: 49_645 + 3000, discount: 10_985.4)
    expect(home.notes).to include('category:home', 'deal_sheet:home')
    expect(deal.selling_price.to_f).to eq((65_656.25 - 10_985.4).round(2))
    setup = products.find { |dp| dp.product_name == 'Set-up and blocking' }
    expect(setup).to have_attributes(unit_price: 2500, source_type: 'template')
    expect(setup.notes).to include('category:fee', 'deal_sheet:')
    expect(deal).to have_attributes(dealer_discount: 3102.81, sales_event_discount: 6205.63,
                                    preferred_payment_discount: 1176.96, manager_discount: 500)

    # The Products form saves by deleting every line and recreating it: the tags carry the lines back to the sheet.
    kept = products.map { |dp| dp.attributes.slice('product_name', 'unit_price', 'cost', 'quantity', 'discount', 'discount_type', 'notes', 'source_type') }
    deal.deal_products.destroy_all
    kept.each { |a| deal.deal_products.create!(a.merge('product_sku' => "CUSTOM-#{SecureRandom.hex(4)}")) }
    post "#{path}/reprice", headers: headers
    expect(deal.reload.deal_products.count).to eq(2)

    # A line someone added in Products shows on the sheet, untouched.
    deal.deal_products.create!(product_name: 'Extended warranty', product_sku: 'CUSTOM-w', unit_price: 900, quantity: 1, notes: 'category:product')
    get path, headers: headers
    expect(body.dig('build', 'other_deal_lines').map { |l| l['name'] }).to eq(['Extended warranty'])

    delete path, headers: headers
    names = deal.reload.deal_products.map(&:product_name)
    expect(names).to include('Extended warranty', home.product_name)
    expect(names).not_to include('Set-up and blocking')
  end

  it 'starts a Deal Desk scenario on a factory order from the price the deal sheet wrote' do
    company.tenant_module_overrides.create!(module_key: 'sales.deal_desk', is_enabled: true)
    fee = company.fee_templates.create!(name: 'Skirting', fee_type: 'setup', default_amount: 1800)
    post path, headers: headers, params: { variant_id: variant.id }.to_json
    post "#{path}/lines", headers: headers, params: { kind: 'template', template_type: 'FeeTemplate', template_id: fee.id }.to_json

    post '/api/v1/deal_desk/scenarios', headers: headers, params: { scenario: { deal_id: deal.id, name: 'Cash' } }.to_json
    expect(response).to have_http_status(:created)
    scenario = DealDeskScenario.find(body.dig('scenario', 'id'))
    expect(scenario.unit_price_snapshot.to_f).to eq(deal.reload.selling_price.to_f)
    expect(scenario.unit_price_snapshot.to_f).to eq(64_036.25)
    expect(scenario.line_items.map { |l| l['description'] }).to include('Skirting')
  end

  it 'lists the options offered on the model, marking what is chosen' do
    post path, headers: headers, params: { variant_id: variant.id }.to_json
    post "#{path}/lines", headers: headers, params: { kind: 'option', option_id: clay.id }.to_json
    get "#{path}/options", headers: headers
    siding = body['groups'].find { |g| g['name'] == 'Exterior' }['options'].select { |o| o['color_set'] == 'Siding' }
    expect(siding.map { |o| [o['name'], o['chosen']] }).to eq([['Clay', true], ['Flint', false]])
    shutters = body['groups'].find { |g| g['name'] == 'Exterior' }['options'].select { |o| o['color_set'] == 'Shutters' }
    expect(shutters.map { |o| o['name'] }).to eq(['Shutters: Black', 'Shutters: Wine'])
    expect(body['groups'].flat_map { |g| g['options'] }.find { |o| o['id'] == beam.id }).to include('unit' => 'lf', 'cost' => 60.0)
  end

  it 'refuses an unpriced model, a locked build, and another company' do
    unpriced = CatalogPlanVariant.create!(catalog_plan: plan, manufacturer: mfr, model_number: '1636H11P01', width_ft: 16, length_ft: 36)
    post path, headers: headers, params: { variant_id: unpriced.id }.to_json
    expect(response).to have_http_status(:unprocessable_entity)

    post path, headers: headers, params: { variant_id: variant.id }.to_json
    deal.home_build.update!(status: 'locked')
    post "#{path}/lines", headers: headers, params: { kind: 'option', option_id: insulation.id }.to_json
    expect(response).to have_http_status(:conflict)

    get path, headers: token(other)
    expect(response).to have_http_status(:not_found)
    their_deal = other.deals.create!(name: 'Theirs', contact_id: other.contacts.create!(first_name: 'A', last_name: 'B', email: 'ab@example.com').id)
    post "/api/v1/deals/#{their_deal.id}/home_build", headers: headers, params: { variant_id: variant.id }.to_json
    expect(response).to have_http_status(:not_found)
  end
end
