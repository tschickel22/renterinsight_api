# frozen_string_literal: true

require 'rails_helper'

# A published price book could not be changed, so a wrong price stayed wrong
# for every dealer. A platform admin now corrects it in place, for everyone at
# once, and a dealer reports a wrong price from the deal sheet.
RSpec.describe 'Price book corrections', type: :request do
  let(:company) { Company.create!(name: "Dealer #{SecureRandom.hex(3)}").tap { |c| c.tenant_module_overrides.create!(module_key: 'sales.configurator', is_enabled: true) } }
  let(:platform) { Company.create!(name: "Platform #{SecureRandom.hex(3)}") }
  let(:mfr) { Manufacturer.create!(name: "Champion #{SecureRandom.hex(3)}", industry_type: 'manufactured_home') }
  let(:factory) { mfr.factories.create!(name: 'Decatur', code: "DEC#{SecureRandom.hex(2)}") }
  let(:book) { CatalogPriceBook.create!(manufacturer: mfr, factory: factory, name: 'Decatur 2026', status: 'published', published_at: 1.day.ago) }
  let(:plan) { CatalogPlan.create!(manufacturer: mfr, factory: factory, series: 'Prime', name: 'Apex') }
  let(:variant) { CatalogPlanVariant.create!(catalog_plan: plan, manufacturer: mfr, model_number: '2856H32P01', width_ft: 28, length_ft: 56) }
  let(:group) { CatalogOptionGroup.create!(manufacturer: mfr, key: 'construction', name: 'Construction', selection_type: 'multiple') }
  let!(:insulation) { CatalogOption.create!(group: group, manufacturer: mfr, key: 'construction--insulation', name: 'Upgrade Insulation', kind: 'upgrade', factory_code: 'INS38') }
  let!(:option_price) { CatalogOptionPrice.create!(price_book: book, option: insulation, dealer_cost: 1295) }
  let!(:base_price) { CatalogVariantPrice.create!(price_book: book, variant: variant, net_base_price: 49_645) }

  def headers_for(co, role)
    user = User.create!(email: "u-#{SecureRandom.hex(4)}@example.com", first_name: 'T', last_name: 'S', password: 'Pass1234!',
                        company_id: co.id, role: role)
    [user, { 'Authorization' => "Bearer #{JsonWebToken.encode(user_id: user.id, company_id: co.id)}", 'Content-Type' => 'application/json' }]
  end
  let(:admin) { headers_for(platform, 'platform_admin').last }
  let(:rep_user_and_headers) { headers_for(company, 'company_admin') }
  let(:rep) { rep_user_and_headers.last }
  let(:buyer) { company.contacts.create!(first_name: 'Pat', last_name: 'Smith', email: 'pat@example.com') }
  let(:deal) { company.deals.create!(name: 'Smith Apex', contact_id: buyer.id) }
  let(:sheet) { "/api/v1/deals/#{deal.id}/home_build" }

  before do
    company.dealer_catalog_terms.create!(price_update_policy: 'auto_all')
    company.dealer_markup_rules.create!(scope_type: 'all', markup_type: 'percent', value: 25)
  end

  def body = JSON.parse(response.body)

  it 'lists a published book and corrects an option for every dealer, logged, repricing open sheets' do
    post sheet, headers: rep, params: { variant_id: variant.id }.to_json
    post "#{sheet}/lines", headers: rep, params: { kind: 'option', option_id: insulation.id }.to_json
    expect(body['build']['lines'].find { |l| l['label'] == 'Upgrade Insulation' }).to include('cost' => 1295.0)

    get "/api/admin/catalog_price_books/#{book.id}/prices", headers: admin, params: { kind: 'option', search: 'ins38' }
    expect(body['rows'].map { |r| [r['name'], r['dealer_cost'], r['applies_to']] }).to eq([['Upgrade Insulation', 1295.0, 'Every home']])

    expect do
      patch "/api/admin/catalog_price_books/#{book.id}/prices/option/#{option_price.id}", headers: admin,
            params: { changes: { dealer_cost: '1395' }, reason: 'Factory bulletin 26-14' }.to_json
    end.to have_enqueued_job(CatalogPriceCorrectionJob).with(book.id)
    expect(body['row']).to include('dealer_cost' => 1395.0, 'corrected' => true)

    get "/api/admin/catalog_price_books/#{book.id}/corrections", headers: admin
    expect(body['corrections'].first).to include('field' => 'dealer_cost', 'old_value' => '1295.0', 'new_value' => '1395.0',
                                                 'reason' => 'Factory bulletin 26-14', 'label' => 'Upgrade Insulation')

    # The dealer's open sheet picks it up when opened.
    get sheet, headers: rep
    expect(body['build']['lines'].find { |l| l['label'] == 'Upgrade Insulation' }).to include('cost' => 1395.0)
  end

  it "sets an option's factory code for the PO, logged like a price" do
    patch "/api/admin/catalog_price_books/#{book.id}/prices/option/#{option_price.id}", headers: admin,
          params: { changes: { factory_code: ' op800999 ' }, reason: 'From the order form' }.to_json
    expect(JSON.parse(response.body)['row']).to include('factory_code' => 'OP800999')
    expect(insulation.reload.factory_code).to eq('OP800999')
    expect(book.corrections.last).to have_attributes(field: 'factory_code', old_value: 'INS38', new_value: 'OP800999')
  end

  it 'refuses a missing base price, an unknown field, and anyone but a platform admin' do
    patch "/api/admin/catalog_price_books/#{book.id}/prices/base/#{base_price.id}", headers: admin, params: { changes: { net_base_price: '' } }.to_json
    expect(response).to have_http_status(:unprocessable_entity)
    patch "/api/admin/catalog_price_books/#{book.id}/prices/option/#{option_price.id}", headers: admin, params: { changes: { series: 'X' } }.to_json
    expect(response).to have_http_status(:unprocessable_entity)
    get "/api/admin/catalog_price_books/#{book.id}/prices", headers: rep
    expect(response).to have_http_status(:forbidden)
  end

  it 'takes a dealer report from the sheet, and applies or dismisses it, telling the rep' do
    post sheet, headers: rep, params: { variant_id: variant.id }.to_json
    post "#{sheet}/lines", headers: rep, params: { kind: 'option', option_id: insulation.id }.to_json
    lines = body['build']['lines']
    option_line = lines.find { |l| l['kind'] == 'option' }
    base_line = lines.find { |l| l['kind'] == 'base' }

    post "#{sheet}/lines/#{option_line['id']}/report_price", headers: rep,
         params: { field: 'cost', suggested_value: 1195, note: 'Bulletin says 1,195' }.to_json
    expect(response).to have_http_status(:created)
    post "#{sheet}/lines/#{base_line['id']}/report_price", headers: rep, params: { field: 'cost', suggested_value: 48_900 }.to_json
    expect(response).to have_http_status(:created)
    post "#{sheet}/lines/#{base_line['id']}/report_price", headers: rep, params: { field: 'price', suggested_value: 1 }.to_json
    expect(response).to have_http_status(:unprocessable_entity)

    get '/api/admin/catalog_price_requests', headers: admin, params: { status: 'open' }
    reqs = body['requests']
    expect(reqs.map { |r| [r['label'], r['current_value'], r['suggested_value']] })
      .to contain_exactly(['Upgrade Insulation on 2856H32P01', 1295.0, 1195.0], ['Apex 2856H32P01 base price', 49_645.0, 48_900.0])

    option_req = reqs.find { |r| r['label'].start_with?('Upgrade') }
    post "/api/admin/catalog_price_requests/#{option_req['id']}/apply", headers: admin
    expect(body['request']).to include('status' => 'applied')
    expect(option_price.reload.dealer_cost.to_f).to eq(1195.0)
    expect(book.corrections.last.reason).to include(company.name, 'Bulletin says 1,195')

    base_req = reqs.find { |r| r['label'].include?('base') }
    post "/api/admin/catalog_price_requests/#{base_req['id']}/dismiss", headers: admin, params: { note: 'Price list is right' }.to_json
    expect(body['request']).to include('status' => 'dismissed', 'resolution_note' => 'Price list is right')
    expect(base_price.reload.net_base_price.to_f).to eq(49_645.0)

    rep_user = rep_user_and_headers.first
    expect(Notification.where(recipient: rep_user, notification_type: 'truebuild_price_request').pluck(:title))
      .to contain_exactly('Price book corrected', 'Price book left as is')
  end

  it 'has nothing to correct on a line that is not from a book' do
    post sheet, headers: rep, params: { variant_id: variant.id }.to_json
    post "#{sheet}/lines", headers: rep, params: { kind: 'custom', label: 'Steps', unit_retail: 600 }.to_json
    custom = body['build']['lines'].find { |l| l['kind'] == 'custom' }
    post "#{sheet}/lines/#{custom['id']}/report_price", headers: rep, params: { field: 'price', suggested_value: 500 }.to_json
    expect(response).to have_http_status(:unprocessable_entity)
  end
end
