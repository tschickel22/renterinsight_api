# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'Api::V1::TruebuildHomes', type: :request do
  let(:company) { Company.create!(name: "Co-#{SecureRandom.hex(4)}").tap { |c| c.tenant_module_overrides.create!(module_key: 'sales.configurator', is_enabled: true) } }
  let(:other) { Company.create!(name: "Other-#{SecureRandom.hex(4)}") }
  let(:mfr) { Manufacturer.create!(name: "Champion #{SecureRandom.hex(3)}", industry_type: 'manufactured_home') }
  # Named as production names it: the plant is how a Dutch Housing home is known to be covered.
  let(:factory) { mfr.factories.create!(name: 'Topeka, Dutch Housing', code: "TOP#{SecureRandom.hex(2)}") }
  let(:book) { CatalogPriceBook.create!(manufacturer: mfr, factory: factory, name: 'Topeka 2026', status: 'published') }
  let(:bay_port) { CatalogPlan.create!(manufacturer: mfr, factory: factory, series: 'Aspire', name: 'Bay Port') }
  let!(:bay56) { variant('2856H32168', 56) }
  let!(:bay60) { variant('2860H32168', 60) }
  let!(:bay56_modular) { variant('2856M32168', 56) }
  let(:admin) do
    user = User.create!(email: "u-#{SecureRandom.hex(4)}@example.com", first_name: 'T', last_name: 'S', password: 'Pass1234!',
                        company_id: company.id, role: 'company_admin')
    { 'Authorization' => "Bearer #{JsonWebToken.encode(user_id: user.id, company_id: company.id)}", 'Content-Type' => 'application/json' }
  end

  def variant(number, length)
    CatalogPlanVariant.create!(catalog_plan: bay_port, manufacturer: mfr, model_number: number, width_ft: 28, length_ft: length).tap do |v|
      CatalogVariantPrice.create!(price_book: book, variant: v, net_base_price: 90_000)
    end
  end

  def home(model, company: self.company, status: 'available_to_order', **attrs)
    Vehicle.create!(company: company, year: 2026, make: 'Dutch Housing', model: model, vin: "VIN#{SecureRandom.hex(6).upcase}",
                    status: status, is_deleted: false, **attrs)
  end

  it 'suggests the model for a home entered by name and length, links one carrying its model number, and links on request' do
    by_name = home("56' Bay Port")
    by_number = home('2860 H32168', status: 'on_order')
    sold = home('Sold One', status: 'sold')
    home("56' Bay Port", company: other)

    get '/api/v1/truebuild_homes', headers: admin
    homes = JSON.parse(response.body)['homes'].index_by { |h| h['id'] }
    expect(homes.keys).to contain_exactly(by_name.id, by_number.id)
    expect(homes[by_name.id]['suggestions'].map { |s| [s['variant_id'], s['reason']] }).to eq([[bay56.id, "Same name and 56' long"]])
    modular = home("56' Bay Port").tap { |v| v.update_columns(home_type: 'Modular') }
    get '/api/v1/truebuild_homes', headers: admin
    expect(JSON.parse(response.body)['homes'].find { |h| h['id'] == modular.id }['suggestions'].map { |s| s['variant_id'] }).to eq([bay56_modular.id])
    expect(homes[by_number.id]['linked']).to include('variant_id' => bay60.id)
    expect(by_number.reload.catalog_plan_variant_id).to eq(bay60.id)

    patch "/api/v1/truebuild_homes/#{by_name.id}", headers: admin, params: { variant_id: bay56.id }.to_json
    expect(by_name.reload.catalog_plan_variant_id).to eq(bay56.id)
    patch "/api/v1/truebuild_homes/#{by_name.id}", headers: admin, params: { variant_id: nil }.to_json
    expect(by_name.reload.catalog_plan_variant_id).to be_nil

    # A sold home is not listed, but it can still be linked to its model.
    patch "/api/v1/truebuild_homes/#{sold.id}", headers: admin, params: { variant_id: bay56.id }.to_json
    expect(sold.reload.catalog_plan_variant_id).to eq(bay56.id)
  end

  it 'links a site-scanned home whose name carries the number, only when the size agrees' do
    scanned = home('Aspire Dap2856 H32168', status: 'available')
    expect(scanned.catalog_plan_variant_id).to eq(bay56.id)

    # Recorded 60' long: suggested, never linked without the dealer.
    off_size = home('Aspire Dap2856 H32168', status: 'available', length: 60)
    expect(off_size.catalog_plan_variant_id).to be_nil
    get '/api/v1/truebuild_homes', headers: admin
    row = JSON.parse(response.body)['homes'].find { |h| h['id'] == off_size.id }
    expect(row['suggestions'].map { |s| [s['variant_id'], s['reason']] }).to eq([[bay56.id, 'Same model number']])
  end

  it 'gives used homes and builders no book covers no model picker' do
    used = home("56' Bay Port", status: 'available', condition: 'used')
    other_builder = home("56' Bay Port", status: 'available', make: 'Fleetwood')
    get '/api/v1/truebuild_homes', headers: admin
    rows = JSON.parse(response.body)['homes'].index_by { |h| h['id'] }
    [used, other_builder].each { |v| expect(rows[v.id]).to include('covered' => false, 'suggestions' => []) }
  end

  it 'sweeps homes saved before they could link themselves' do
    earlier = home('Bay Port 2856H32168')
    earlier.update_columns(catalog_plan_variant_id: nil)
    ambiguous = home('2856 H32168 or 2860 H32168')

    expect(Truebuild::HomeMatcher.new.link_all(company.vehicles, dry_run: true)).to eq([[earlier.id, '2856H32168']])
    expect(earlier.reload.catalog_plan_variant_id).to be_nil
    Truebuild::HomeMatcher.new.link_all(company.vehicles)
    expect(earlier.reload.catalog_plan_variant_id).to eq(bay56.id)
    expect(ambiguous.reload.catalog_plan_variant_id).to be_nil
  end

  it "refuses a model no published book prices, and another company's home" do
    unpriced = CatalogPlanVariant.create!(catalog_plan: bay_port, manufacturer: mfr, model_number: '2876H32168', width_ft: 28, length_ft: 76)
    mine = home("56' Bay Port")
    patch "/api/v1/truebuild_homes/#{mine.id}", headers: admin, params: { variant_id: unpriced.id }.to_json
    expect(response).to have_http_status(:unprocessable_entity)

    theirs = home("56' Bay Port", company: other)
    patch "/api/v1/truebuild_homes/#{theirs.id}", headers: admin, params: { variant_id: bay56.id }.to_json
    expect(response).to have_http_status(:not_found)
    expect(theirs.reload.catalog_plan_variant_id).to be_nil
  end
end
