# frozen_string_literal: true

require 'rails_helper'

# The factory PO (E51): written from the deal's LIVE Deal Sheet, linked to the
# deal, received into inventory without posting anything.
RSpec.describe 'Factory PO from the Deal Sheet', type: :request do
  let(:company) { Company.create!(name: "Co-#{SecureRandom.hex(4)}").tap { |c| c.tenant_module_overrides.create!(module_key: 'sales.configurator', is_enabled: true) } }
  let(:mfr) { Manufacturer.create!(name: "Champion #{SecureRandom.hex(3)}", industry_type: 'manufactured_home') }
  let(:factory) { mfr.factories.create!(name: 'Decatur', code: "DEC#{SecureRandom.hex(2)}") }
  let(:book) { CatalogPriceBook.create!(manufacturer: mfr, factory: factory, name: 'Decatur 2026', status: 'published', published_at: 1.day.ago) }
  let(:plan) { CatalogPlan.create!(manufacturer: mfr, factory: factory, series: 'Prime', name: 'Apex') }
  let(:variant) { CatalogPlanVariant.create!(catalog_plan: plan, manufacturer: mfr, model_number: '2856H32P01', width_ft: 28, length_ft: 56, beds: 3, baths: 2) }
  let(:group) { CatalogOptionGroup.create!(manufacturer: mfr, key: 'construction', name: 'Construction', selection_type: 'multiple') }
  let!(:insulation) do
    CatalogOption.create!(group: group, manufacturer: mfr, key: 'construction--insulation', name: 'Upgrade Insulation', kind: 'upgrade', factory_code: 'INS38').tap do |o|
      CatalogOptionPrice.create!(price_book: book, option: o, dealer_cost: 1295)
    end
  end
  let(:headers) do
    user = User.create!(email: "u-#{SecureRandom.hex(4)}@example.com", first_name: 'T', last_name: 'S', password: 'Pass1234!',
                        company_id: company.id, role: 'company_admin')
    { 'Authorization' => "Bearer #{JsonWebToken.encode(user_id: user.id, company_id: company.id)}", 'Content-Type' => 'application/json' }
  end
  let(:buyer) { company.contacts.create!(first_name: 'Pat', last_name: 'Smith', email: 'pat@example.com') }
  let(:deal) { company.deals.create!(name: 'Smith Apex', contact_id: buyer.id, delivery_street: '1 Main St', delivery_city: 'Auburn', delivery_state: 'IN', delivery_zip: '46706') }
  let(:path) { "/api/v1/deals/#{deal.id}/home_build" }

  before do
    CatalogVariantPrice.create!(price_book: book, variant: variant, net_base_price: 49_645)
    company.dealer_catalog_terms.create!(price_update_policy: 'auto_all')
    company.dealer_markup_rules.create!(scope_type: 'all', markup_type: 'percent', value: 25)
    AccountingSettings.for_company(company).update!(auto_post_purchase_orders: true)
    post path, headers: headers, params: { variant_id: variant.id }.to_json
    post "#{path}/lines", headers: headers, params: { kind: 'option', option_id: insulation.id, quantity: 2 }.to_json
    company.fee_templates.create!(name: 'Doc fee', fee_type: 'doc', default_amount: 300).then do |fee|
      post "#{path}/lines", headers: headers, params: { kind: 'template', template_type: 'FeeTemplate', template_id: fee.id }.to_json
    end
  end

  def body = JSON.parse(response.body)

  it "writes the home and its factory options, suggests the factory's supplier, and notices when the sheet changes" do
    decatur = company.suppliers.create!(name: "#{mfr.name} Decatur")
    company.suppliers.create!(name: 'Acme Skirting')
    get "#{path}/suppliers", headers: headers
    expect(body['suggested_id']).to eq(decatur.id)

    post "#{path}/purchase_order", headers: headers, params: { supplier_id: decatur.id }.to_json
    expect(response).to have_http_status(:created)
    po = deal.purchase_orders.last
    expect(po).to have_attributes(kind: 'factory_home', status: 'draft', supplier_id: decatur.id, ship_to_city: 'Auburn')
    expect(po.lines.order(:line_number).map { |l| [l.description, l.manufacturer_part_no, l.quantity_ordered.to_f, l.unit_cost.to_f] })
      .to eq([["#{mfr.name} Apex 2856H32P01", '2856H32P01', 1.0, 49_645.0], ['Upgrade Insulation', 'INS38', 2.0, 1295.0]])
    expect(po.total_amount.to_f).to eq(49_645 + 2590)
    expect(body.dig('build', 'purchase_orders').first).to include('po_number' => po.po_number, 'changed_since' => false)

    patch "#{path}/lines/#{po.lines.last.catalog_option_id && deal.home_build.lines.find_by(kind: 'option').id}", headers: headers, params: { quantity: 3 }.to_json
    expect(body.dig('build', 'purchase_orders').first['changed_since']).to be(true)

    post "#{path}/purchase_order/#{po.id}/refresh", headers: headers
    expect(po.reload.lines.find_by(manufacturer_part_no: 'INS38').quantity_ordered.to_f).to eq(3.0)
    expect(body.dig('purchase_order', 'changed_since')).to be(false)

    get "/api/v1/purchase-orders/#{po.id}", headers: headers
    expect(body['deal']).to include('id' => deal.id)
    expect(body['lines'].first['part_name']).to eq("#{mfr.name} Apex 2856H32P01")
  end

  it 'receives the home into inventory, links it to the deal and posts nothing' do
    post "#{path}/purchase_order", headers: headers, params: { supplier_name: "#{mfr.name} Decatur" }.to_json
    po = deal.purchase_orders.last
    expect(po.supplier.name).to eq("#{mfr.name} Decatur")

    post "/api/v1/purchase-orders/#{po.id}/receive-home", headers: headers, params: { serial_number: 'DEC123456AB' }.to_json
    expect(response).to have_http_status(:ok)
    home = company.vehicles.find(body['received_vehicle_id'])
    expect(home).to have_attributes(serial_number: 'DEC123456AB', listing_type: 'manufactured_home', status: 'reserved',
                                    catalog_plan_variant_id: variant.id, bedrooms: 3, model: 'Apex 2856H32P01')
    expect(po.reload.status).to eq('received')
    expect(deal.reload.vehicle_id).to eq(home.id)
    expect(company.journal_entries.where(source_entity_type: 'PurchaseOrder', source_entity_id: po.id)).to be_empty

    post "/api/v1/purchase-orders/#{po.id}/receive-home", headers: headers, params: { serial_number: 'X' }.to_json
    expect(response).to have_http_status(:unprocessable_entity)
  end

  it 'will not order a draft version or a home already on the lot' do
    post "#{path}/versions", headers: headers, params: { copy_from_id: deal.home_build.id }.to_json
    draft = body['build']['id']
    supplier = company.suppliers.create!(name: 'Factory')
    post "#{path}/purchase_order?version_id=#{draft}", headers: headers, params: { supplier_id: supplier.id }.to_json
    expect(response).to have_http_status(:unprocessable_entity)
    expect(body['error']).to include('LIVE')
  end
end
