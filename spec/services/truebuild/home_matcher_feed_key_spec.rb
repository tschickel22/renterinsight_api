# frozen_string_literal: true

require 'rails_helper'

# A feed listing links to the price book model by the feed's own key, which
# the photo linking recorded on the model: Clayton's "DOGWOOD" carries no
# number, Cavco's "28603A" is too short to trust alone.
RSpec.describe Truebuild::HomeMatcher, '#by_feed_key' do
  let(:company) { Company.create!(name: "Co-#{SecureRandom.hex(4)}") }
  let(:mfr) { Manufacturer.create!(name: "Clayton #{SecureRandom.hex(3)}", industry_type: 'manufactured_home') }
  let(:factory) { mfr.factories.create!(name: 'TRU', code: "TRU#{SecureRandom.hex(2)}") }
  let(:book) { CatalogPriceBook.create!(manufacturer: mfr, factory: factory, name: 'TRU', status: 'published', published_at: Time.current) }

  def model(name, number, ids, series: 'Tru Origin')
    plan = CatalogPlan.create!(manufacturer: mfr, factory: factory, series: series, name: name)
    v = CatalogPlanVariant.create!(catalog_plan: plan, manufacturer: mfr, series: series, model_number: number, building_code: 'HUD', external_ids: ids)
    CatalogVariantPrice.create!(price_book: book, variant: v, net_base_price: 60_000)
    v
  end

  def listing(key, model: 'DOGWOOD', condition: nil)
    company.vehicles.create!(listing_type: 'manufactured_home', status: 'available_to_order', year: 2026, make: 'Clayton',
                             model: model, condition: condition, bedrooms: 3, bathrooms: 2.0, serial_number: "SN-#{SecureRandom.hex(4)}", catalog_source_key: key)
  end

  it 'links a new feed listing as it is saved' do
    dogwood = model('Dogwood', '47TRT14602DH', { 'feed_key' => '47TRT14602DH' })
    expect(listing('47TRT14602DH').catalog_plan_variant_id).to eq(dogwood.id)
  end

  it 'links Cavco listings by floorplan id, and leaves a key two models claim alone' do
    ashley = model('Ashley', '28603A', { 'cavco_floorplan_id' => 'd1' }, series: 'Elite')
    model('Craft Select', '28603A', { 'cavco_floorplan_id' => 'd2' }, series: 'Craft Select')
    model('Cavco Select', '28603A', { 'cavco_floorplan_id' => 'd2' }, series: 'Cavco Select')

    expect(listing('d1', model: 'Ashley 28603A').catalog_plan_variant_id).to eq(ashley.id)
    expect(listing('d2', model: 'Craft Select 28603A').catalog_plan_variant_id).to be_nil
  end

  it 'links listings saved before the match, and never a used home' do
    old = listing('47TRT14563EH', model: 'ELM')
    used = listing('47TRT14563EH', model: 'ELM', condition: 'used')
    elm = model('Elm', '47TRT14563EH', { 'feed_key' => '47TRT14563EH' })

    linked = described_class.new.link_by_feed_key_all(company.vehicles)
    expect(linked).to eq([[old.id, '47TRT14563EH']])
    expect(old.reload.catalog_plan_variant_id).to eq(elm.id)
    expect(used.reload.catalog_plan_variant_id).to be_nil
  end
end
