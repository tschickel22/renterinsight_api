# frozen_string_literal: true

require 'rails_helper'

# A deal holds several versions of its sheet; only the LIVE one writes the deal.
RSpec.describe 'Deal sheet versions', type: :request do
  let(:company) { Company.create!(name: "Co-#{SecureRandom.hex(4)}").tap { |c| c.tenant_module_overrides.create!(module_key: 'sales.configurator', is_enabled: true) } }
  let(:mfr) { Manufacturer.create!(name: "Champion #{SecureRandom.hex(3)}", industry_type: 'manufactured_home') }
  let(:factory) { mfr.factories.create!(name: 'Decatur', code: "DEC#{SecureRandom.hex(2)}") }
  let(:book) { CatalogPriceBook.create!(manufacturer: mfr, factory: factory, name: 'Decatur 2026', status: 'published', published_at: 1.day.ago) }
  let(:plan) { CatalogPlan.create!(manufacturer: mfr, factory: factory, series: 'Prime', name: 'Apex') }
  let(:variant) { CatalogPlanVariant.create!(catalog_plan: plan, manufacturer: mfr, model_number: '2856H32P01', width_ft: 28, length_ft: 56) }
  let(:smaller) { CatalogPlanVariant.create!(catalog_plan: plan, manufacturer: mfr, model_number: '1676H32P01', width_ft: 16, length_ft: 76) }
  let(:group) { CatalogOptionGroup.create!(manufacturer: mfr, key: 'construction', name: 'Construction', selection_type: 'multiple') }
  let!(:insulation) do
    CatalogOption.create!(group: group, manufacturer: mfr, key: 'construction--insulation', name: 'Upgrade Insulation', kind: 'upgrade').tap do |o|
      CatalogOptionPrice.create!(price_book: book, option: o, dealer_cost: 1295)
    end
  end
  let(:headers) do
    user = User.create!(email: "u-#{SecureRandom.hex(4)}@example.com", first_name: 'T', last_name: 'S', password: 'Pass1234!',
                        company_id: company.id, role: 'company_admin')
    { 'Authorization' => "Bearer #{JsonWebToken.encode(user_id: user.id, company_id: company.id)}", 'Content-Type' => 'application/json' }
  end
  let(:buyer) { company.contacts.create!(first_name: 'Pat', last_name: 'Smith', email: 'pat@example.com') }
  let(:deal) { company.deals.create!(name: 'Smith Apex', contact_id: buyer.id) }
  let(:path) { "/api/v1/deals/#{deal.id}/home_build" }

  before do
    CatalogVariantPrice.create!(price_book: book, variant: variant, net_base_price: 49_645)
    CatalogVariantPrice.create!(price_book: book, variant: smaller, net_base_price: 40_000)
    company.dealer_catalog_terms.create!(price_update_policy: 'auto_all')
    company.dealer_markup_rules.create!(scope_type: 'all', markup_type: 'percent', value: 25)
  end

  def body = JSON.parse(response.body)
  def home_line = deal.deal_products.reload.find { |dp| dp.notes.to_s.include?('deal_sheet:home') }

  it 'copies a version as a draft that leaves the deal alone until it is made live' do
    post path, headers: headers, params: { variant_id: variant.id }.to_json
    v1 = body['build']
    expect(v1).to include('version_number' => 1, 'live' => true, 'version_name' => 'Version 1')
    live_price = home_line.unit_price.to_f

    post "#{path}/versions", headers: headers, params: { copy_from_id: v1['id'], label: 'With insulation' }.to_json
    expect(response).to have_http_status(:created)
    v2 = body['build']
    expect(v2).to include('version_number' => 2, 'live' => false, 'version_name' => 'Version 2: With insulation')
    expect(v2['lines'].map { |l| l['kind'] }).to eq(v1['lines'].map { |l| l['kind'] })

    post "#{path}/lines", headers: headers, params: { version_id: v2['id'], kind: 'option', option_id: insulation.id }.to_json
    expect(body.dig('build', 'live')).to be(false)
    expect(body.dig('build', 'totals', 'gross')).to be > v1.dig('totals', 'gross')
    # The draft priced the insulation; the deal still carries version 1.
    expect(home_line.unit_price.to_f).to eq(live_price)
    get path, headers: headers
    expect(body.dig('build', 'id')).to eq(v1['id'])
    expect(body.dig('build', 'versions').map { |v| [v['version_number'], v['live']] }).to eq([[1, true], [2, false]])

    post "#{path}/make_live", headers: headers, params: { version_id: v2['id'] }.to_json
    expect(body.dig('build', 'live')).to be(true)
    expect(home_line.unit_price.to_f).to eq(live_price + (1295 * 1.25))
    expect(deal.home_builds.reload.map { |b| [b.version_number, b.live] }).to eq([[1, false], [2, true]])
    expect(deal.deal_products.reload.count { |dp| dp.notes.to_s.include?('deal_sheet:home') }).to eq(1)
  end

  it 'starts a version on another home, renames it, and will not delete the live one' do
    post path, headers: headers, params: { variant_id: variant.id }.to_json
    v1 = body['build']['id']
    post "#{path}/versions", headers: headers, params: { variant_id: smaller.id }.to_json
    v2 = body['build']
    expect(v2).to include('live' => false, 'label' => nil)
    expect(v2['model']).to include('model_number' => '1676H32P01')

    patch path, headers: headers, params: { version_id: v2['id'], label: 'Single wide' }.to_json
    expect(body.dig('build', 'version_name')).to eq('Version 2: Single wide')

    delete "#{path}?version_id=#{v1}", headers: headers
    expect(response).to have_http_status(:unprocessable_entity)
    delete "#{path}?version_id=#{v2['id']}", headers: headers
    expect(response).to have_http_status(:no_content)
    expect(deal.home_builds.reload.map(&:id)).to eq([v1])
  end

  it 'will not switch versions while the live one is signed' do
    post path, headers: headers, params: { variant_id: variant.id }.to_json
    v1 = body['build']['id']
    post "#{path}/versions", headers: headers, params: { copy_from_id: v1 }.to_json
    v2 = body['build']['id']
    deal.home_build.update!(status: 'locked')

    post "#{path}/make_live", headers: headers, params: { version_id: v2 }.to_json
    expect(response).to have_http_status(:conflict)
    expect(deal.home_build.reload.id).to eq(v1)
  end
end
