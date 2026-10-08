# frozen_string_literal: true

require 'rails_helper'

# Products and the Deal Sheet are one record: what the Products form saves
# (delete every line, recreate the list) comes back onto the LIVE sheet.
RSpec.describe 'Deal sheet and Products, both ways', type: :request do
  let(:company) { Company.create!(name: "Co-#{SecureRandom.hex(4)}").tap { |c| c.tenant_module_overrides.create!(module_key: 'sales.configurator', is_enabled: true) } }
  let(:mfr) { Manufacturer.create!(name: "Champion #{SecureRandom.hex(3)}", industry_type: 'manufactured_home') }
  let(:factory) { mfr.factories.create!(name: 'Decatur', code: "DEC#{SecureRandom.hex(2)}") }
  let(:book) { CatalogPriceBook.create!(manufacturer: mfr, factory: factory, name: 'Decatur 2026', status: 'published', published_at: 1.day.ago) }
  let(:plan) { CatalogPlan.create!(manufacturer: mfr, factory: factory, series: 'Prime', name: 'Apex') }
  let(:variant) { CatalogPlanVariant.create!(catalog_plan: plan, manufacturer: mfr, model_number: '2856H32P01', width_ft: 28, length_ft: 56) }
  let(:headers) do
    user = User.create!(email: "u-#{SecureRandom.hex(4)}@example.com", first_name: 'T', last_name: 'S', password: 'Pass1234!',
                        company_id: company.id, role: 'company_admin')
    { 'Authorization' => "Bearer #{JsonWebToken.encode(user_id: user.id, company_id: company.id)}", 'Content-Type' => 'application/json' }
  end
  let(:buyer) { company.contacts.create!(first_name: 'Pat', last_name: 'Smith', email: 'pat@example.com') }
  let(:deal) { company.deals.create!(name: 'Smith Apex', contact_id: buyer.id) }
  let(:path) { "/api/v1/deals/#{deal.id}/home_build" }
  let(:fence) { company.fee_templates.create!(name: 'Fencing', fee_type: 'other', default_amount: 500) }

  before do
    CatalogVariantPrice.create!(price_book: book, variant: variant, net_base_price: 49_645)
    company.dealer_catalog_terms.create!(price_update_policy: 'auto_all')
    company.dealer_markup_rules.create!(scope_type: 'all', markup_type: 'percent', value: 25)
    post path, headers: headers, params: { variant_id: variant.id }.to_json
    post "#{path}/lines", headers: headers, params: { kind: 'template', template_type: 'FeeTemplate', template_id: fence.id }.to_json
  end

  def body = JSON.parse(response.body)
  def sheet_line(label) = deal.home_build.lines.reload.find { |l| l.label == label }

  # What the Products form sends: every line, as it now stands, after deleting them all.
  def save_products(&edit)
    rows = deal.reload.deal_products.map do |dp|
      dp.attributes.slice('product_name', 'unit_price', 'cost', 'quantity', 'notes', 'tax', 'discount', 'discount_type')
        .merge('product_sku' => "CUSTOM-#{SecureRandom.hex(3)}")
    end
    rows = edit.call(rows)
    deal.deal_products.each { |dp| delete "/api/crm/deals/#{deal.id}/products/#{dp.id}", headers: headers }
    post "/api/crm/deals/#{deal.id}/products/bulk_create", headers: headers, params: { products: rows }.to_json
    expect(response).to have_http_status(:created)
  end

  it 'makes a line added in Products a sheet line, and takes its later price and name changes' do
    save_products do |rows|
      rows + [{ 'product_name' => 'Sewer Hookup', 'unit_price' => 800, 'cost' => 500, 'quantity' => 1, 'tax' => 0,
                'notes' => 'category:service, taxable:no', 'discount' => 0, 'discount_type' => 'fixed', 'product_sku' => 'CUSTOM-sewer' }]
    end
    sewer = sheet_line('Sewer Hookup')
    expect(sewer).to have_attributes(kind: 'custom', retail: 800, cost: 500)
    dp = deal.deal_products.reload.find { |p| p.product_name == 'Sewer Hookup' }
    expect(dp.notes).to include("deal_sheet:#{sewer.id}", 'taxable:no')
    expect(deal.deal_products.count).to eq(3) # home, fence, sewer: nothing doubled

    save_products do |rows|
      rows.map { |r| r['product_name'] == 'Fencing' ? r.merge('product_name' => 'Privacy fence', 'unit_price' => 650, 'cost' => 400) : r }
    end
    expect(sheet_line('Privacy fence')).to have_attributes(retail: 650, cost: 400)
    get path, headers: headers
    expect(body.dig('build', 'other_deal_lines')).to eq([])
  end

  it 'removes a sheet line removed in Products, and keeps the home line however Products saves' do
    save_products { |rows| rows.reject { |r| r['product_name'] == 'Fencing' } }
    expect(sheet_line('Fencing')).to be_nil
    expect(deal.deal_products.reload.map(&:product_name)).to eq([deal.deal_products.find(&:home_line_item?).product_name])

    # Every line removed: the home comes back, since its price is the sheet's.
    deal.deal_products.each { |dp| delete "/api/crm/deals/#{deal.id}/products/#{dp.id}", headers: headers }
    post "/api/crm/deals/#{deal.id}/products/bulk_create", headers: headers, params: { products: [] }.to_json
    expect(deal.deal_products.reload.count(&:home_line_item?)).to eq(1)
  end

  it 'leaves a draft version alone' do
    post "#{path}/versions", headers: headers, params: { copy_from_id: deal.home_build.id }.to_json
    draft = deal.home_builds.reload.find { |b| !b.live }
    save_products { |rows| rows.reject { |r| r['product_name'] == 'Fencing' } }
    expect(draft.lines.reload.map(&:label)).to include('Fencing')
  end
end
