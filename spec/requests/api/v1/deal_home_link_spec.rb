# frozen_string_literal: true

require 'rails_helper'

# A deal shows its home even when it was priced on the Deal Sheet, the serial
# typed on the deal makes the real home, and inventory asks which buyer a new
# home is for when more than one deal waits on the same model (2026-11-23).
RSpec.describe 'Deal home link', type: :request do
  let(:company) do
    Company.create!(name: "Easy #{SecureRandom.hex(3)}").tap do |c|
      c.tenant_module_overrides.create!(module_key: 'sales.configurator', is_enabled: true)
      c.dealer_catalog_terms.create!(price_update_policy: 'auto_all')
      c.dealer_markup_rules.create!(scope_type: 'all', markup_type: 'percent', value: 25)
    end
  end
  let(:mfr) { Manufacturer.create!(name: "Clayton #{SecureRandom.hex(3)}", industry_type: 'manufactured_home') }
  let(:factory) { mfr.factories.create!(name: 'TRU', code: "TRU#{SecureRandom.hex(2)}") }
  let(:book) { CatalogPriceBook.create!(manufacturer: mfr, factory: factory, name: 'TRU 2026', status: 'published', published_at: 1.day.ago) }
  let(:plan) { CatalogPlan.create!(manufacturer: mfr, factory: factory, series: 'Tru Origin', name: 'Maple') }
  let(:variant) { CatalogPlanVariant.create!(catalog_plan: plan, manufacturer: mfr, model_number: '42TRT28483MH', building_code: 'HUD', width_ft: 28, length_ft: 48, beds: 3, baths: 2) }
  let!(:base_price) { CatalogVariantPrice.create!(price_book: book, variant: variant, net_base_price: 45_645) }
  let(:showroom) { company.locations.create!(name: 'Showroom', timezone: 'America/Denver') }
  let(:headers) do
    user = User.create!(email: "u-#{SecureRandom.hex(4)}@example.com", first_name: 'T', last_name: 'S', password: 'Pass1234!', company_id: company.id, role: 'company_admin')
    { 'Authorization' => "Bearer #{JsonWebToken.encode(user_id: user.id, company_id: company.id)}", 'Content-Type' => 'application/json' }
  end

  def body = JSON.parse(response.body)

  def listing
    @listing ||= company.vehicles.create!(listing_type: 'manufactured_home', status: 'available_to_order', year: 2026, make: 'Clayton', model: 'MAPLE',
                                          serial_number: "CAT-#{SecureRandom.hex(3)}", bedrooms: 3, bathrooms: 2.0, source: 'catalog_import',
                                          catalog_plan_variant_id: variant.id, inventory_id: "MH-#{SecureRandom.hex(4)}")
  end

  def new_deal(name = 'Smith Maple')
    contact = company.contacts.create!(first_name: 'Pat', last_name: name, email: "pat-#{SecureRandom.hex(3)}@example.com")
    company.deals.create!(name: name, contact_id: contact.id, location_id: showroom.id)
  end

  def sheet(deal, vehicle: nil)
    post "/api/v1/deals/#{deal.id}/home_build", headers: headers, params: { variant_id: variant.id, vehicle_id: vehicle&.id }.compact.to_json
    expect(response).to have_http_status(:created)
    deal.reload
  end

  def serial(deal, **params)
    post "/api/v1/deals/#{deal.id}/home/serial", headers: headers, params: params.to_json
  end

  describe 'the Deal Sheet links the deal to its home' do
    it 'a sheet started from the catalog model points the deal at that model\'s available-to-order home' do
      listing
      deal = sheet(new_deal)
      expect(deal.vehicle_id).to eq(listing.id)
      expect(deal.home_build.vehicle_id).to be_nil # the sheet keeps pricing as a factory order
    end

    it 'a sheet started from a home on the lot points the deal at that home' do
      lot = company.vehicles.create!(listing_type: 'manufactured_home', status: 'available', year: 2026, make: 'Clayton', model: 'MAPLE',
                                     serial_number: "SN-#{SecureRandom.hex(3)}", bedrooms: 3, bathrooms: 2.0, catalog_plan_variant_id: variant.id)
      deal = sheet(new_deal, vehicle: lot)
      expect(deal.vehicle_id).to eq(lot.id)
    end

    it 'leaves a home someone picked on the deal' do
      listing
      picked = company.vehicles.create!(listing_type: 'manufactured_home', status: 'available', year: 2024, make: 'Other', model: 'Home',
                                        serial_number: "SN-#{SecureRandom.hex(3)}", bedrooms: 3, bathrooms: 2.0)
      deal = new_deal
      deal.update!(vehicle_id: picked.id)
      expect(sheet(deal).vehicle_id).to eq(picked.id)
    end

    it 'links nothing when the model has no single available-to-order home' do
      deal = sheet(new_deal)
      expect(deal.vehicle_id).to be_nil
    end
  end

  describe 'a serial number on the deal' do
    it 'on a model\'s available-to-order home makes the dealer\'s copy for this buyer; the listing stays' do
      listing
      deal = sheet(new_deal)
      serial(deal, serial_number: 'CLT123456', status: 'on_order')
      expect(response).to have_http_status(:ok)
      home = company.vehicles.find(body.dig('home', 'id'))
      expect(home).to have_attributes(serial_number: 'CLT123456', status: 'on_order', cloned_from_id: listing.id)
      expect(deal.reload.vehicle_id).to eq(home.id)
      expect(deal.home_build.vehicle_id).to eq(home.id)
      expect(listing.reload).to have_attributes(status: 'available_to_order', is_deleted: false)
    end

    it 'with no home in inventory makes a new one from the model' do
      deal = sheet(new_deal)
      serial(deal, serial_number: 'CLT999', vin: 'abc123')
      expect(response).to have_http_status(:ok)
      home = company.vehicles.find(body.dig('home', 'id'))
      expect(home).to have_attributes(serial_number: 'CLT999', vin: 'ABC123', status: 'on_order', catalog_plan_variant_id: variant.id, bedrooms: 3)
      expect(deal.reload.vehicle_id).to eq(home.id)
    end

    it 'on a home already the dealer\'s just records it' do
      deal = sheet(new_deal)
      serial(deal, serial_number: 'FIRST')
      id = body.dig('home', 'id')
      serial(deal, serial_number: 'SECOND', status: 'available')
      expect(body.dig('home', 'id')).to eq(id)
      expect(company.vehicles.find(id)).to have_attributes(serial_number: 'SECOND', status: 'available')
    end

    it 'already on another home asks to link that one instead' do
      other = company.vehicles.create!(listing_type: 'manufactured_home', status: 'available', year: 2026, make: 'Clayton', model: 'MAPLE',
                                       serial_number: 'DUP-1', bedrooms: 3, bathrooms: 2.0)
      deal = sheet(new_deal)
      serial(deal, serial_number: 'dup-1')
      expect(response).to have_http_status(:conflict)
      expect(body.dig('existing', 'id')).to eq(other.id)

      serial(deal, serial_number: 'DUP-1', use_existing_id: other.id)
      expect(response).to have_http_status(:ok)
      expect(deal.reload.vehicle_id).to eq(other.id)
      expect(company.vehicles.where(serial_number: 'DUP-1').count).to eq(1)
    end

    it 'on a won deal marks the home sold to this buyer' do
      listing
      deal = sheet(new_deal)
      deal.update_columns(stage: 'closed_won')
      serial(deal, serial_number: 'WON-1')
      home = company.vehicles.find(body.dig('home', 'id'))
      expect(home).to have_attributes(status: 'sold', sold_via_deal_id: deal.id)
    end

    it 'needs a serial or VIN' do
      deal = sheet(new_deal)
      serial(deal, serial_number: ' ')
      expect(response).to have_http_status(:unprocessable_entity)
    end
  end

  describe 'inventory: a status on an available-to-order home' do
    before { listing }

    def set_status(params = {})
      patch "/api/v1/vehicles/#{listing.id}", headers: headers, params: { vehicle: { status: 'available' } }.merge(params).to_json
    end

    it 'with one deal waiting, the new home is that deal\'s' do
      deal = sheet(new_deal)
      set_status
      expect(response).to have_http_status(:created)
      expect(body['linked_deal_id']).to eq(deal.id)
      expect(deal.reload.vehicle_id).to eq(body['clone_id'])
    end

    it 'with two waiting, asks which buyer, and only that deal moves' do
      first = sheet(new_deal('Smith'))
      second = sheet(new_deal('Jones'))
      set_status
      expect(response).to have_http_status(:conflict)
      expect(body['choose_deal'].map { |d| d['id'] }).to eq([first.id, second.id])
      expect(listing.clones.count).to eq(0)

      set_status(for_deal_id: second.id)
      expect(response).to have_http_status(:created)
      expect(second.reload.vehicle_id).to eq(body['clone_id'])
      expect(second.home_build.vehicle_id).to eq(body['clone_id'])
      expect(first.reload.vehicle_id).to eq(listing.id)
      expect(first.home_build.vehicle_id).to be_nil
    end

    it 'for stock leaves every deal waiting' do
      first = sheet(new_deal('Smith'))
      sheet(new_deal('Jones'))
      set_status(for_deal_id: 'none')
      expect(response).to have_http_status(:created)
      expect(body['linked_deal_id']).to be_nil
      expect(first.reload.vehicle_id).to eq(listing.id)
    end
  end
end
