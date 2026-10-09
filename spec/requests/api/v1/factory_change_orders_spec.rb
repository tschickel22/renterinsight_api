# frozen_string_literal: true

require 'rails_helper'

# Once the factory PO is sent, a change on the LIVE Deal Sheet goes to the
# factory as a change order (backlog E52, phase 1): what changed against what
# the factory has, the production status, the cost difference. Approved, it
# rewrites the PO; one is open at a time.
RSpec.describe 'Factory change orders', type: :request do
  let(:company) { Company.create!(name: "Co-#{SecureRandom.hex(4)}").tap { |c| c.tenant_module_overrides.create!(module_key: 'sales.configurator', is_enabled: true) } }
  let(:mfr) { Manufacturer.create!(name: "Champion #{SecureRandom.hex(3)}", industry_type: 'manufactured_home') }
  let(:factory) { mfr.factories.create!(name: 'Decatur', code: "DEC#{SecureRandom.hex(2)}") }
  let(:book) { CatalogPriceBook.create!(manufacturer: mfr, factory: factory, name: 'Decatur 2026', status: 'published', published_at: 1.day.ago) }
  let(:plan) { CatalogPlan.create!(manufacturer: mfr, factory: factory, series: 'Prime', name: 'Apex') }
  let(:variant) { CatalogPlanVariant.create!(catalog_plan: plan, manufacturer: mfr, model_number: '2856H32P01', width_ft: 28, length_ft: 56) }
  let(:group) { CatalogOptionGroup.create!(manufacturer: mfr, key: 'construction', name: 'Construction', selection_type: 'multiple') }
  let!(:insulation) do
    CatalogOption.create!(group: group, manufacturer: mfr, key: 'construction--insulation', name: 'Upgrade Insulation', kind: 'upgrade', factory_code: 'INS38')
                 .tap { |o| CatalogOptionPrice.create!(price_book: book, option: o, dealer_cost: 1295) }
  end
  let!(:beam) do
    CatalogOption.create!(group: group, manufacturer: mfr, key: 'construction--beam', name: 'Wood Beam On Ceiling - Per LF', kind: 'upgrade')
                 .tap { |o| CatalogOptionPrice.create!(price_book: book, option: o, dealer_cost: 60) }
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
    company.dealer_catalog_terms.create!(price_update_policy: 'auto_all')
    post path, headers: headers, params: { variant_id: variant.id }.to_json
    post "#{path}/lines", headers: headers, params: { kind: 'option', option_id: insulation.id }.to_json
  end

  def body = JSON.parse(response.body)
  def cos(po) = "/api/v1/purchase-orders/#{po.id}/change-orders"

  it 'writes, sends and approves a change order, and the PO takes it' do
    post "#{path}/purchase_order", headers: headers, params: { supplier_name: 'Factory' }.to_json
    po = deal.purchase_orders.last
    post cos(po), headers: headers, params: {}.to_json
    expect(response).to have_http_status(:unprocessable_entity) # a draft is updated, not changed
    post "/api/v1/purchase-orders/#{po.id}/send", headers: headers

    get cos(po), headers: headers
    expect(body['pending']).to be_nil

    sheet_line = deal.home_build.lines.find_by(catalog_option_id: insulation.id)
    patch "#{path}/lines/#{sheet_line.id}", headers: headers, params: { quantity: 2 }.to_json
    post "#{path}/lines", headers: headers, params: { kind: 'option', option_id: beam.id, quantity: 12 }.to_json
    get cos(po), headers: headers
    expect(body['pending']['lines'].map { |l| [l['change'], l['description']] })
      .to contain_exactly(%w[quantity Upgrade\ Insulation], ['add', 'Wood Beam On Ceiling - Per LF'])
    expect(body['pending']['cost_delta'].to_f).to eq(1295.0 + 720.0)

    post cos(po), headers: headers, params: { production_status: 'released', notes: 'Customer added a beam' }.to_json
    expect(response).to have_http_status(:created)
    co = po.change_orders.first
    expect(co).to have_attributes(number: 1, status: 'draft', production_status: 'released', cost_delta: 2015)
    post cos(po), headers: headers, params: {}.to_json
    expect(body['error']).to include("#{po.po_number}-CO1 is still open")

    text = PDF::Reader.new(StringIO.new(ChangeOrderPdfGenerator.new(co).generate)).pages.map(&:text).join("\n")
    expect(text).to include('CHANGE ORDER', "#{po.po_number}-CO1", 'Released to production', 'Wood Beam On Ceiling', '1 to 2', '$2,015.00')

    Setting.set('Platform', 0, 'communications', { 'email' => { 'from_address' => 'noreply@example.com' } })
    expect do
      post "#{cos(po)}/#{co.id}/email", headers: headers, params: { to: 'orders@factory.example' }.to_json
    end.to change { ActionMailer::Base.deliveries.size }.by(1)
    expect(co.reload).to have_attributes(status: 'sent', emailed_to: 'orders@factory.example')

    post "#{cos(po)}/#{co.id}/approve", headers: headers
    expect(co.reload.status).to eq('approved')
    expect(po.reload.lines.map { |l| [l.description, l.quantity_ordered.to_f] })
      .to include(['Upgrade Insulation', 2.0], ['Wood Beam On Ceiling - Per LF', 12.0])
    expect(Truebuild::FactoryOrder.changed?(po)).to be(false)
    get cos(po), headers: headers
    expect(body['pending']).to be_nil
  end

  it 'reports color changes, refreshes a draft and voids one' do
    exterior = CatalogOptionGroup.create!(manufacturer: mfr, key: 'exterior', name: 'Exterior', selection_type: 'multiple')
    clay, flint = %w[Clay Flint].map do |n|
      CatalogOption.create!(group: exterior, manufacturer: mfr, key: "exterior--siding-#{n.downcase}", name: n, kind: 'color',
                            metadata: { 'color_set' => 'Siding' }).tap { |o| CatalogOptionPrice.create!(price_book: book, option: o, is_standard: true) }
    end
    post "#{path}/lines", headers: headers, params: { kind: 'option', option_id: clay.id }.to_json
    post "#{path}/purchase_order", headers: headers, params: { supplier_name: 'Factory' }.to_json
    po = deal.purchase_orders.last
    post "/api/v1/purchase-orders/#{po.id}/send", headers: headers

    post "#{path}/lines", headers: headers, params: { kind: 'option', option_id: flint.id }.to_json
    post cos(po), headers: headers, params: {}.to_json
    co = po.change_orders.first
    expect(co.colors).to eq([{ 'set' => 'Siding', 'from' => 'Clay', 'to' => 'Flint' }])
    expect(co.lines).to be_empty

    post "#{path}/lines", headers: headers, params: { kind: 'option', option_id: beam.id, quantity: 3 }.to_json
    patch "#{cos(po)}/#{co.id}", headers: headers, params: {}.to_json
    expect(co.reload.lines.map { |l| l['change'] }).to eq(['add'])

    post "#{cos(po)}/#{co.id}/void", headers: headers
    expect(co.reload.status).to eq('void')
    expect(Truebuild::FactoryOrder.changed?(po)).to be(true) # the PO still holds the old order
  end
end
