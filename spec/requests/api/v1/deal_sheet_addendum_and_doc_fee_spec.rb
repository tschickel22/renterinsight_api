# frozen_string_literal: true

require 'rails_helper'

# Tom, 2026-11-02: a line typed in step 2 never reached Addendum A. The rep now
# ticks it on: it counts on Addendum A and stays on the dealer's list for every
# sheet after, until unticked. The same list is kept in Settings, beside their
# colors. The document fee is set once in Settings and is required and read only
# on the sheet. Retail can round up to $1 or 10 cents.
RSpec.describe 'Deal Sheet Addendum A, dealer upgrades and the document fee', type: :request do
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
  let(:extras) { CatalogOptionGroup.create!(manufacturer: mfr, key: 'construction', name: 'Construction', selection_type: 'multiple') }
  let!(:dishwasher) do
    CatalogOption.create!(group: extras, manufacturer: mfr, key: 'dishwasher', name: 'Dishwasher', kind: 'upgrade').tap do |o|
      CatalogOptionPrice.create!(price_book: book, option: o, dealer_cost: 340)
    end
  end
  let!(:base_price) { CatalogVariantPrice.create!(price_book: book, variant: variant, net_base_price: 50_000) }

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
    post "/api/v1/deals/#{deal.id}/home_build", headers: h, params: { variant_id: variant.id }.to_json
    expect(response).to have_http_status(:created)
    deal
  end

  def path(deal) = "/api/v1/deals/#{deal.id}/home_build"
  def body = JSON.parse(response.body)
  def lines = body.dig('build', 'lines')
  def line_named(name) = lines.find { |l| l['label'] == name }

  def add_custom(deal, **attrs)
    post "#{path(deal)}/lines", headers: headers, params: { kind: 'custom', label: 'Gutters', unit_retail: 800, unit_cost: 500, **attrs }.to_json
    expect(response).to have_http_status(:created)
  end

  def order_form(deal, h = headers)
    get "#{path(deal)}/options", headers: h
    body['groups'].flat_map { |g| g['options'] }
  end

  def set_terms(**attrs)
    put '/api/v1/truebuild_pricing/terms', headers: headers, params: attrs.to_json
    expect(response).to have_http_status(:ok)
  end

  describe 'a typed line ticked for Addendum A' do
    it 'stays off Addendum A until ticked, then counts on it and the contract ladder' do
      deal = sheet_for(company, headers)
      add_custom(deal)
      line = line_named('Gutters')
      expect(line['kind']).to eq('custom')
      expect(Truebuild::AgreementSheets.new(deal.reload.home_build).options_total).to eq(0)

      patch "#{path(deal)}/lines/#{line['id']}", headers: headers, params: { on_addendum: true }.to_json
      expect(response).to have_http_status(:ok)
      line = line_named('Gutters')
      expect(line).to include('kind' => 'option', 'dealer_upgrade' => true, 'retail' => 800.0, 'unit_cost' => 500.0, 'tax_category' => 'factory_option')

      build = deal.reload.home_build
      sheets = Truebuild::AgreementSheets.new(build)
      expect(sheets.options_total).to eq(800)
      expect(sheets.schedule_rows.map { |r| r['description'] }).to include('Gutters')
      values = Agreements::PacketValues.new(deal).to_h
      expect(values['price.options']).to eq('$800.00')
      expect(values).not_to have_key('price.other_label')
      # The contract's ladder still adds up to the gross.
      expect(sheets.base_price + sheets.options_total + build.lines.find_by(kind: 'freight').retail.to_d).to eq(build.totals['gross'].to_d)
      # It rolls into the home line like any option, so it is not written to the deal twice.
      expect(deal.deal_products.reload.map(&:product_name)).not_to include('Gutters')
    end

    it 'is offered on the next sheet, picked or not, and prices the same' do
      deal = sheet_for(company, headers)
      add_custom(deal, on_addendum: true)
      upgrade = company.dealer_colors.find_by!(name: 'Gutters')

      next_deal = sheet_for(company, headers)
      expect(lines.map { |l| l['label'] }).not_to include('Gutters')
      row = order_form(next_deal).find { |o| o['id'] == upgrade.id }
      expect(row).to include('name' => 'Gutters', 'dealer_upgrade' => true, 'price' => 800.0)

      post "#{path(next_deal)}/lines", headers: headers, params: { kind: 'option', option_id: upgrade.id }.to_json
      expect(line_named('Gutters')).to include('kind' => 'option', 'retail' => 800.0, 'cost' => 500.0)
      expect(Truebuild::AgreementSheets.new(next_deal.reload.home_build).options_total).to eq(800)
    end

    it 'typed again under the same name uses the same upgrade, and this deal keeps the price typed' do
      deal = sheet_for(company, headers)
      add_custom(deal, on_addendum: true)
      again = sheet_for(company, headers)
      add_custom(again, label: 'gutters', unit_retail: 950, on_addendum: true)

      expect(company.dealer_colors.where(kind: 'upgrade').count).to eq(1)
      expect(line_named('Gutters')).to include('retail' => 950.0, 'set_retail' => true)
      expect(order_form(again).find { |o| o['dealer_upgrade'] }['price']).to eq(800.0)
    end

    it 'unticked comes off Addendum A and off the list, and a sheet that has it keeps it' do
      keeper = sheet_for(company, headers)
      add_custom(keeper, on_addendum: true)
      upgrade = company.dealer_colors.find_by!(name: 'Gutters')
      deal = sheet_for(company, headers)
      post "#{path(deal)}/lines", headers: headers, params: { kind: 'option', option_id: upgrade.id }.to_json
      line = line_named('Gutters')

      patch "#{path(deal)}/lines/#{line['id']}", headers: headers, params: { on_addendum: false }.to_json
      expect(response).to have_http_status(:ok)
      expect(line_named('Gutters')).to include('kind' => 'custom', 'retail' => 800.0, 'unit_cost' => 500.0, 'tax_category' => 'other', 'dealer_upgrade' => false)
      expect(Truebuild::AgreementSheets.new(deal.reload.home_build).options_total).to eq(0)
      expect(deal.deal_products.reload.map(&:product_name)).to include('Gutters')
      expect(order_form(deal).map { |o| o['name'] }).not_to include('Gutters')
      expect(upgrade.reload.status).to eq('discontinued')

      post "#{path(keeper)}/reprice", headers: headers
      expect(line_named('Gutters')).to include('kind' => 'option', 'retail' => 800.0, 'not_offered' => false)
      expect(body.dig('build', 'warnings').join).not_to include('not offered')

      # Ticking it again brings the same upgrade back.
      patch "#{path(deal)}/lines/#{line['id']}", headers: headers, params: { on_addendum: true }.to_json
      expect(upgrade.reload.status).to eq('active')
      expect(company.dealer_colors.where(kind: 'upgrade').count).to eq(1)
    end

    it 'leaves fee and service lines to their own contract rows' do
      deal = sheet_for(company, headers)
      add_custom(deal, label: 'Set-up sold by dealer', tax_category: 'setup')
      patch "#{path(deal)}/lines/#{line_named('Set-up sold by dealer')['id']}", headers: headers, params: { on_addendum: true }.to_json
      expect(response).to have_http_status(:unprocessable_entity)
    end

    it 'goes on the factory PO unless marked as the dealer supplying it' do
      deal = sheet_for(company, headers)
      add_custom(deal, on_addendum: true)
      add_custom(deal, label: 'Landscaping', on_addendum: true, factory_order: false)
      descriptions = Truebuild::FactoryOrder.lines(deal.reload.home_build).map { |l| l['description'] }
      expect(descriptions).to include('Gutters')
      expect(descriptions).not_to include('Landscaping')
    end

    it 'is refused on a signed sheet' do
      deal = sheet_for(company, headers)
      add_custom(deal)
      id = line_named('Gutters')['id']
      deal.reload.home_build.update!(status: 'locked')
      patch "#{path(deal)}/lines/#{id}", headers: headers, params: { on_addendum: true }.to_json
      expect(response).to have_http_status(:conflict)
    end

    it "stays with the dealer who added it, and off the buyer's designer" do
      deal = sheet_for(company, headers)
      add_custom(deal, on_addendum: true)
      upgrade = company.dealer_colors.find_by!(name: 'Gutters')

      other_headers = headers_for(other)
      other_deal = sheet_for(other, other_headers)
      expect(order_form(other_deal, other_headers).map { |o| o['name'] }).not_to include('Gutters')
      post "#{path(other_deal)}/lines", headers: other_headers, params: { kind: 'option', option_id: upgrade.id }.to_json
      expect(response).to have_http_status(:unprocessable_entity)
      post "#{path(other_deal)}/upgrades/remove", headers: other_headers, params: { option_id: upgrade.id }.to_json
      expect(response).to have_http_status(:not_found)

      offered = Truebuild::OptionSource.offered(book, variant).map(&:catalog_option_id)
      expect(offered).not_to include(upgrade.id)
    end
  end

  describe 'dealer upgrades in Settings' do
    it 'adds, edits and removes one, and a deal sheet picks it up at the price set' do
      post '/api/v1/truebuild_pricing/upgrades', headers: headers,
                                                 params: { manufacturer_id: mfr.id, name: 'Storm Doors', factory_code: 'sd1', cost: '200', retail: '450' }.to_json
      expect(response).to have_http_status(:created)
      id = body['id']
      expect(body).to include('name' => 'Storm Doors', 'factory_code' => 'SD1', 'cost' => 200.0, 'retail' => 450.0, 'factory_order' => true)

      get '/api/v1/truebuild_pricing/upgrades', headers: headers, params: { manufacturer_id: mfr.id }
      expect(body['upgrades'].map { |u| u['name'] }).to eq(['Storm Doors'])

      deal = sheet_for(company, headers)
      expect(order_form(deal).find { |o| o['id'] == id }).to include('price' => 450.0, 'cost' => 200.0, 'standard' => false)

      patch "/api/v1/truebuild_pricing/upgrades/#{id}", headers: headers, params: { retail: '500', factory_order: false }.to_json
      expect(body).to include('retail' => 500.0, 'factory_order' => false)
      expect(order_form(deal).find { |o| o['id'] == id }['price']).to eq(500.0)

      delete "/api/v1/truebuild_pricing/upgrades/#{id}", headers: headers
      expect(response).to have_http_status(:no_content)
      expect(order_form(deal).map { |o| o['id'] }).not_to include(id)
    end

    it 'prices at the price set with no cost, and from markup with no price' do
      post '/api/v1/truebuild_pricing/upgrades', headers: headers, params: { manufacturer_id: mfr.id, name: 'Price only', retail: '300' }.to_json
      price_only = body['id']
      post '/api/v1/truebuild_pricing/upgrades', headers: headers, params: { manufacturer_id: mfr.id, name: 'Cost only', cost: '100' }.to_json
      cost_only = body['id']
      deal = sheet_for(company, headers)
      rows = order_form(deal)
      expect(rows.find { |o| o['id'] == price_only }).to include('price' => 300.0, 'standard' => false)
      expect(rows.find { |o| o['id'] == cost_only }['price']).to eq(125.0)
    end

    it "keeps other dealers out of it" do
      post '/api/v1/truebuild_pricing/upgrades', headers: headers, params: { manufacturer_id: mfr.id, name: 'Mine', retail: '1' }.to_json
      id = body['id']
      patch "/api/v1/truebuild_pricing/upgrades/#{id}", headers: headers_for(other), params: { name: 'Theirs' }.to_json
      expect(response).to have_http_status(:not_found)
    end

    it 'goes to the platform admin, who can make it everyone or turn it down' do
      post '/api/v1/truebuild_pricing/upgrades', headers: headers, params: { manufacturer_id: mfr.id, name: 'Storm Doors', cost: '200', retail: '450' }.to_json
      upgrade = CatalogOption.find(body['id'])
      request = company.catalog_option_requests.find_by!(catalog_option_id: upgrade.id)
      expect(request).to have_attributes(action: 'add', status: 'open')

      Truebuild::OptionRequests.new(request, user: nil).apply!
      expect(upgrade.reload.company_id).to be_nil
      other_headers = headers_for(other)
      other_deal = sheet_for(other, other_headers)
      expect(order_form(other_deal, other_headers).find { |o| o['id'] == upgrade.id }).to include('price' => 250.0, 'cost' => 200.0)

      post '/api/v1/truebuild_pricing/upgrades', headers: headers, params: { manufacturer_id: mfr.id, name: 'Turned down', retail: '10' }.to_json
      turned_down = CatalogOption.find(body['id'])
      Truebuild::OptionRequests.new(company.catalog_option_requests.find_by!(catalog_option_id: turned_down.id), user: nil).dismiss!
      deal = sheet_for(company, headers)
      expect(order_form(deal).map { |o| o['id'] }).not_to include(turned_down.id)
    end
  end

  describe 'the document fee' do
    it 'warns until set, then is on the sheet, the deal and the contract, read only' do
      deal = sheet_for(company, headers)
      expect(body.dig('build', 'warnings')).to include(Truebuild::DealBuild::DOC_FEE_MISSING)
      expect(body.dig('build', 'doc_fee')).to be_nil

      set_terms(doc_fee: 395)
      get path(deal), headers: headers # an open sheet picks it up when next opened
      line = line_named('Doc fee')
      expect(line).to include('kind' => 'custom', 'retail' => 395.0, 'required_fee' => true, 'tax_category' => 'fee')
      expect(body.dig('build', 'doc_fee')).to eq(395.0)
      expect(body.dig('build', 'warnings')).not_to include(Truebuild::DealBuild::DOC_FEE_MISSING)

      deal.reload
      expect(deal.deal_products.find_by(product_name: 'Doc fee').unit_price).to eq(395)
      expect(deal.effective_doc_fee).to eq(395.0)
      expect(Agreements::PacketValues.new(deal).to_h['price.doc_fee']).to eq('$395.00')

      patch "#{path(deal)}/lines/#{line['id']}", headers: headers, params: { unit_retail: 1 }.to_json
      expect(response).to have_http_status(:unprocessable_entity)
      expect(body['error']).to eq(Truebuild::DealBuild::DOC_FEE_LOCKED)
      patch "#{path(deal)}/lines/#{line['id']}", headers: headers, params: { no_charge: true }.to_json
      expect(response).to have_http_status(:unprocessable_entity)
      delete "#{path(deal)}/lines/#{line['id']}", headers: headers
      expect(response).to have_http_status(:unprocessable_entity)

      set_terms(doc_fee: 450)
      get path(deal), headers: headers
      expect(lines.count { |l| l['required_fee'] }).to eq(1)
      expect(line_named('Doc fee')['retail']).to eq(450.0)
    end

    it 'is on a new sheet from the start, and a copy carries one' do
      set_terms(doc_fee: 300)
      deal = sheet_for(company, headers)
      expect(line_named('Doc fee')['retail']).to eq(300.0)
      post "#{path(deal)}/versions", headers: headers, params: { copy_from_id: deal.home_build.id }.to_json
      expect(lines.count { |l| l['required_fee'] }).to eq(1)
    end

    it 'replaces a doc fee line already on the sheet instead of charging it twice' do
      template = company.fee_templates.create!(name: 'Documentation Fee', fee_type: 'doc', default_amount: 150)
      deal = sheet_for(company, headers)
      post "#{path(deal)}/lines", headers: headers, params: { kind: 'template', template_type: 'FeeTemplate', template_id: template.id }.to_json
      add_custom(deal, label: 'Document preparation fee', unit_retail: 200, unit_cost: 0, tax_category: 'fee')
      add_custom(deal, label: 'Title work', unit_retail: 75, unit_cost: 0, tax_category: 'fee')
      expect(lines.count { |l| l['tax_category'] == 'fee' }).to eq(3)

      set_terms(doc_fee: 395)
      get path(deal), headers: headers
      fees = lines.select { |l| l['tax_category'] == 'fee' }
      expect(fees.map { |l| [l['label'], l['retail']] }).to contain_exactly(['Doc fee', 395.0], ['Title work', 75.0])

      get "#{path(deal)}/options", headers: headers
      expect(body['templates'].map { |t| t['name'] }).not_to include('Documentation Fee')
      deal.reload
      names = deal.deal_products.map(&:product_name)
      expect(names).to include('Doc fee', 'Title work')
      expect(names).not_to include('Documentation Fee', 'Document preparation fee')
    end

    it 'takes in a doc fee entered in Products and does not let Products change it' do
      set_terms(doc_fee: 395)
      deal = sheet_for(company, headers)
      fee_line = deal.reload.deal_products.find_by(product_name: 'Doc fee')
      fee_line.update!(unit_price: 1)
      deal.deal_products.create!(product_name: 'Doc Fee', product_sku: 'X', quantity: 1, unit_price: 99, cost: 0, tax: 0, discount: 0, discount_type: 'fixed', notes: 'category:fee')
      Truebuild::DealBuild.new(deal.home_build).take_products!

      deal.reload
      expect(deal.deal_products.select { |dp| dp.product_name.to_s.casecmp?('doc fee') }.map(&:unit_price)).to eq([395])
      expect(deal.home_build.lines.select(&:required_fee?).map(&:unit_retail)).to eq([395])
    end

    it 'set to zero leaves no line and no warning' do
      set_terms(doc_fee: 0)
      sheet_for(company, headers)
      expect(lines.select { |l| l['tax_category'] == 'fee' }).to be_empty
      expect(body.dig('build', 'doc_fee')).to eq(0.0)
      expect(body.dig('build', 'warnings')).not_to include(Truebuild::DealBuild::DOC_FEE_MISSING)
    end

    it 'leaves a signed sheet, and a draft change to it, as sold' do
      deal = sheet_for(company, headers)
      add_custom(deal, label: 'Document preparation fee', unit_retail: 200, unit_cost: 0, tax_category: 'fee')
      live = deal.reload.home_build
      live.update!(status: 'locked')
      set_terms(doc_fee: 395)

      get path(deal), headers: headers
      expect(line_named('Document preparation fee')['retail']).to eq(200.0)
      post "#{path(deal)}/versions", headers: headers, params: { copy_from_id: live.id }.to_json
      expect(response).to have_http_status(:created)
      expect(line_named('Document preparation fee')['retail']).to eq(200.0)
      expect(line_named('Doc fee')).to be_nil
    end

    it 'cleared, the line goes back to one the rep can type in' do
      set_terms(doc_fee: 395)
      deal = sheet_for(company, headers)
      set_terms(doc_fee: nil)
      get path(deal), headers: headers
      line = line_named('Doc fee')
      expect(line['required_fee']).to be(false)
      patch "#{path(deal)}/lines/#{line['id']}", headers: headers, params: { unit_retail: 100 }.to_json
      expect(response).to have_http_status(:ok)
      expect(line_named('Doc fee')['retail']).to eq(100.0)
    end

    it 'takes only a zero or more' do
      put '/api/v1/truebuild_pricing/terms', headers: headers, params: { doc_fee: -1 }.to_json
      expect(response).to have_http_status(:unprocessable_entity)
    end

    it 'stays out of what a buyer sees on the website' do
      set_terms(doc_fee: 395, price_display: 'full')
      result = Truebuild::PricingEngine.new(company: company, variant: variant, include_freight: false).call
      expect(result.lines.map { |l| l[:label] }).not_to include('Doc fee')
      expect(result.totals[:retail]).to eq(62_500.0)
    end
  end

  describe 'rounding retail up' do
    let(:term) { DealerCatalogTerm.new(round_retail_to: step) }

    {
      1 => { '1234.01' => '1235', '1234.00' => '1234' },
      0.1 => { '1234.01' => '1234.1', '1234.10' => '1234.1', '1234.11' => '1234.2' },
      100 => { '1234.01' => '1300' }
    }.each do |value, cases|
      context "to #{value}" do
        let(:step) { value }

        cases.each do |amount, rounded|
          it "takes #{amount} to #{rounded}" do
            expect(Truebuild::PricingEngine.round_retail(BigDecimal(amount), term)).to eq(BigDecimal(rounded))
          end
        end
      end
    end

    it 'saves a 10 cent step, rounds a sheet to it and says so, and an open sheet follows' do
      deal = sheet_for(company, headers)
      add_custom(deal, label: 'Awning', unit_retail: 100.03, unit_cost: 0)
      gross = body.dig('build', 'totals', 'gross')
      expect(gross.to_d.frac).not_to eq(0)

      set_terms(round_retail_to: 0.1)
      get '/api/v1/truebuild_pricing', headers: headers
      expect(body.dig('defaults', 'round_retail_to')).to eq(0.1)

      get path(deal), headers: headers
      totals = body.dig('build', 'totals')
      expect(totals['rounded_to']).to eq(0.1)
      expect(totals['gross'].to_d).to eq((gross.to_d * 10).ceil.to_d / 10)

      set_terms(round_retail_to: 1)
      get path(deal), headers: headers
      expect(body.dig('build', 'totals', 'gross').to_d).to eq(gross.to_d.ceil)
      expect(body.dig('build', 'totals', 'rounded_to')).to eq(1.0)
    end

    it 'refuses a step of zero' do
      put '/api/v1/truebuild_pricing/terms', headers: headers, params: { round_retail_to: 0 }.to_json
      expect(response).to have_http_status(:unprocessable_entity)
    end
  end
end
