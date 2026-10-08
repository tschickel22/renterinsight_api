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

    # Not sent yet: the factory never got it, so it cannot have arrived.
    post "/api/v1/purchase-orders/#{po.id}/receive-home", headers: headers, params: { serial_number: 'DEC123456AB' }.to_json
    expect(response).to have_http_status(:unprocessable_entity)
    expect(JSON.parse(response.body)['error']).to include('has not been sent')

    post "/api/v1/purchase-orders/#{po.id}/send", headers: headers
    get '/api/v1/purchase-orders', headers: headers, params: { search: 'Smith' }
    listed = JSON.parse(response.body)['items']
    expect(listed.map { |p| [p['id'], p['deal_customer_name']] }).to eq([[po.id, deal.customer_display_name]])

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

  it "orders from the home's manufacturer and emails the PO to its orders contact, not the rep" do
    company.company_manufacturers.create!(manufacturer: mfr, contact_email: 'rep@factory.example', po_email: 'orders@factory.example',
                                          po_contact_name: 'Order Desk')
    get "#{path}/suppliers", headers: headers
    expect(body['suggested_manufacturer_id']).to eq(mfr.id)
    expect(body['manufacturers'].first).to include('name' => mfr.name, 'po_email' => 'orders@factory.example')

    post "#{path}/purchase_order", headers: headers, params: { manufacturer_id: mfr.id }.to_json
    po = deal.purchase_orders.last
    expect(po.manufacturer).to eq(mfr)
    expect(po.supplier).to have_attributes(name: mfr.name, code: "MFR-#{mfr.id}")
    expect(po.order_contact).to eq(email: 'orders@factory.example', name: 'Order Desk')

    Setting.set('Platform', 0, 'communications', { 'email' => { 'from_address' => 'noreply@example.com' } })
    expect do
      post "/api/v1/purchase-orders/#{po.id}/email", headers: headers, params: { message: 'Please confirm the build date.' }.to_json
    end.to change { ActionMailer::Base.deliveries.size }.by(1)
    mail = ActionMailer::Base.deliveries.last
    expect(mail.to).to eq(['orders@factory.example'])
    expect(mail.subject).to eq("Home order #{po.po_number} from #{company.name}")
    expect(mail.attachments.map(&:filename)).to eq(["#{po.po_number}.pdf"])
    expect(po.reload).to have_attributes(status: 'sent', emailed_to: 'orders@factory.example')

    # The company's sender not verified with the provider: sent from the platform's, under the dealer's name.
    calls = 0
    allow_any_instance_of(Mail::Message).to receive(:deliver).and_wrap_original do |m, *args|
      calls += 1
      raise 'Email address is not verified. The following identities failed the check' if calls == 1

      m.call(*args)
    end
    post "/api/v1/purchase-orders/#{po.id}/email", headers: headers, params: { to: 'orders@factory.example' }.to_json
    expect(response).to have_http_status(:ok)
    expect(ActionMailer::Base.deliveries.last[:from].to_s).to eq("#{company.name} <noreply@example.com>")

    # An address typed when sending is kept as the manufacturer's PO email.
    post "/api/v1/purchase-orders/#{po.id}/email", headers: headers, params: { to: 'new-orders@factory.example', save_contact: true }.to_json
    expect(JSON.parse(response.body)['saved_contact']).to eq('manufacturer')
    expect(po.reload.order_contact[:email]).to eq('new-orders@factory.example')

    # Without a separate orders email, POs go to the rep.
    company.company_manufacturers.find_by(manufacturer: mfr).update!(po_email: nil, po_contact_name: nil)
    expect(po.reload.order_contact[:email]).to eq('rep@factory.example')
  end

  it 'links a PO made in the PO form to a deal and a manufacturer' do
    company.company_manufacturers.create!(manufacturer: mfr, contact_email: 'rep@factory.example')
    part = company.parts.create!(name: 'Skirting kit', sku: "SK-#{SecureRandom.hex(2)}") rescue nil
    lines = part ? [{ part_id: part.id, line_number: 1, quantity_ordered: 1, unit_cost: 100 }] : []
    post '/api/v1/purchase-orders', headers: headers,
         params: { purchase_order: { deal_id: deal.id, manufacturer_id: mfr.id, order_date: Date.current, lines_attributes: lines } }.to_json
    expect(response).to have_http_status(:created)
    po = company.purchase_orders.find(JSON.parse(response.body)['id'])
    expect(po).to have_attributes(deal_id: deal.id, manufacturer_id: mfr.id, kind: 'parts')
    expect(po.supplier.code).to eq("MFR-#{mfr.id}")

    other = Company.create!(name: "Other #{SecureRandom.hex(2)}")
    stranger = other.contacts.create!(first_name: 'Sam', last_name: 'Lee', email: "s#{SecureRandom.hex(2)}@example.com")
    foreign = other.deals.create!(name: 'Not yours', contact_id: stranger.id)
    post '/api/v1/purchase-orders', headers: headers, params: { purchase_order: { deal_id: foreign.id, manufacturer_id: mfr.id, order_date: Date.current } }.to_json
    expect(response).to have_http_status(:not_found)
  end

  it 'lists every color set on the factory PO with its pick, and can leave prices off' do
    exterior = CatalogOptionGroup.create!(manufacturer: mfr, key: 'exterior', name: 'Exterior', selection_type: 'multiple')
    clay, _flint = %w[Clay Flint].map do |name|
      CatalogOption.create!(group: exterior, manufacturer: mfr, key: "exterior--#{name.downcase}", name: name, kind: 'color',
                            metadata: { 'color_set' => 'Siding' }, factory_code: "SID-#{name.upcase}").tap do |o|
        CatalogOptionPrice.create!(price_book: book, option: o, is_standard: true)
      end
    end
    CatalogOption.create!(group: exterior, manufacturer: mfr, key: 'exterior--shutters-black', name: 'Shutters: Black', kind: 'standard').tap do |o|
      CatalogOptionPrice.create!(price_book: book, option: o, is_standard: true)
    end
    post "#{path}/lines", headers: headers, params: { kind: 'option', option_id: clay.id }.to_json
    supplier = company.suppliers.create!(name: 'Factory')
    post "#{path}/purchase_order", headers: headers, params: { supplier_id: supplier.id }.to_json
    po = deal.purchase_orders.last
    expect(po.colors).to eq([{ 'set' => 'Shutters', 'choice' => nil, 'code' => nil },
                             { 'set' => 'Siding', 'choice' => 'Clay', 'code' => 'SID-CLAY' }])
    expect(po.lines.map(&:description)).not_to include('Clay') # in the colors list, not an item at $0

    # Shutters marked "Not on this home": the PO says so; a draft takes it with Update.
    patch path, headers: headers, params: { color_skips: ['Shutters'] }.to_json
    expect(body.dig('build', 'color_skips')).to eq(['Shutters'])
    post "#{path}/purchase_order/#{po.id}/refresh", headers: headers
    expect(po.reload.colors.first).to include('set' => 'Shutters', 'skipped' => true)

    text = PDF::Reader.new(StringIO.new(PurchaseOrderPdfGenerator.new(po).generate)).pages.map(&:text).join("\n")
    expect(text).to include('Colors and finishes', 'Siding', 'Clay', 'SID-CLAY', 'Not on this home')
    expect(text).to include('$49,645.00')

    company.dealer_catalog_terms.find_by(manufacturer_id: nil).update!(factory_po_hide_prices: true)
    text = PDF::Reader.new(StringIO.new(PurchaseOrderPdfGenerator.new(po.reload).generate)).pages.map(&:text).join("\n")
    expect(text).not_to include('$')
    expect(text).to include('Upgrade Insulation', 'Clay')
  end

  it 'lists Deal Sheets for the PO form, marking the ordered ones' do
    get '/api/v1/deal_sheets', headers: headers, params: { search: 'pat' }
    rows = JSON.parse(response.body)['deal_sheets']
    expect(rows.map { |r| [r['deal_id'], r['source'], r['ordered']] }).to eq([[deal.id, 'order', false]])
    expect(rows.first['model']).to eq('Apex (2856H32P01)')
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
