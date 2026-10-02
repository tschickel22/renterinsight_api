# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'Api::V1::TruebuildHomes', type: :request do
  let(:company) { Company.create!(name: "Co-#{SecureRandom.hex(4)}").tap { |c| c.tenant_module_overrides.create!(module_key: 'sales.configurator', is_enabled: true) } }
  let(:other) { Company.create!(name: "Other-#{SecureRandom.hex(4)}") }
  let(:mfr) { Manufacturer.create!(name: "Champion #{SecureRandom.hex(3)}", industry_type: 'manufactured_home') }
  let(:factory) { mfr.factories.create!(name: 'Topeka', code: "TOP#{SecureRandom.hex(2)}") }
  let(:book) { CatalogPriceBook.create!(manufacturer: mfr, factory: factory, name: 'Topeka 2026', status: 'published') }
  let(:bay_port) { CatalogPlan.create!(manufacturer: mfr, factory: factory, series: 'Aspire', name: 'Bay Port') }
  let!(:bay56) { variant('2856H32168', 56) }
  let!(:bay60) { variant('2860H32168', 60) }
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

  def home(model, company: self.company, status: 'available_to_order')
    Vehicle.create!(company: company, year: 2026, make: 'Dutch Housing', model: model, vin: "VIN#{SecureRandom.hex(6).upcase}",
                    status: status, is_deleted: false)
  end

  it 'suggests the model for a home entered by name and length, or by model number, and links it' do
    by_name = home("56' Bay Port")
    by_number = home('2860 H32168', status: 'on_order')
    home('Sold One', status: 'sold')
    home("56' Bay Port", company: other)

    get '/api/v1/truebuild_homes', headers: admin
    homes = JSON.parse(response.body)['homes'].index_by { |h| h['id'] }
    expect(homes.keys).to contain_exactly(by_name.id, by_number.id)
    expect(homes[by_name.id]['suggestions'].map { |s| [s['variant_id'], s['reason']] }).to eq([[bay56.id, "Same name and 56' long"]])
    expect(homes[by_number.id]['suggestions'].first).to include('variant_id' => bay60.id, 'reason' => 'Same model number')

    patch "/api/v1/truebuild_homes/#{by_name.id}", headers: admin, params: { variant_id: bay56.id }.to_json
    expect(by_name.reload.catalog_plan_variant_id).to eq(bay56.id)
    patch "/api/v1/truebuild_homes/#{by_name.id}", headers: admin, params: { variant_id: nil }.to_json
    expect(by_name.reload.catalog_plan_variant_id).to be_nil
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
