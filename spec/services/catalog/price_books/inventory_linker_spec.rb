# frozen_string_literal: true

require 'rails_helper'

# A home arriving from any dealer's Champion feed links to its factory model.
RSpec.describe Catalog::PriceBooks::InventoryLinker do
  let(:mfr) { Manufacturer.create!(name: "Champion #{SecureRandom.hex(3)}", industry_type: 'manufactured_home') }
  let(:plan) { CatalogPlan.create!(manufacturer: mfr, series: 'Aspire', name: 'Belvidere') }
  let(:dealer) { Company.create!(name: "Dealer #{SecureRandom.hex(3)}") }

  def variant(number, champion_id)
    CatalogPlanVariant.create!(catalog_plan: plan, manufacturer: mfr, model_number: number,
                               external_ids: { 'champion_model_id' => champion_id })
  end

  def feed_home(champion_id, code: 'HUD')
    dealer.vehicles.create!(make: 'Champion', model: 'Aspire Belvidere', year: 2026, source: 'champion_ims',
                            serial_number: "S#{SecureRandom.hex(4)}", vin: "V#{SecureRandom.hex(6)}",
                            champion_model_id: champion_id, champion_raw_payload: { 'buildingCode' => { 'code' => code } })
  end

  it 'links a home from a feed to its factory model when it is saved' do
    hud = variant('2856H32392', 'g-belv')
    expect(feed_home('g-belv').catalog_plan_variant_id).to eq(hud.id)
  end

  it 'uses the building code in the feed when the HUD and modular builds share a site model' do
    variant('2856H32392', 'g-belv')
    mod = variant('2856M32392', 'g-belv')
    expect(feed_home('g-belv', code: 'MOD').catalog_plan_variant_id).to eq(mod.id)
  end

  it 'leaves a home unlinked rather than guess' do
    variant('2856H32392', 'g-belv')
    variant('2856M32392', 'g-belv')
    expect(feed_home('g-belv', code: '').catalog_plan_variant_id).to be_nil
    expect(feed_home('unknown-model').catalog_plan_variant_id).to be_nil
  end

  it 'links homes that arrived before the book was published' do
    home = feed_home('g-belv')
    expect(home.catalog_plan_variant_id).to be_nil

    hud = variant('2856H32392', 'g-belv')
    described_class.link_all(['g-belv'])
    expect(home.reload.catalog_plan_variant_id).to eq(hud.id)
  end

  it 'leaves an existing link alone' do
    other = variant('2860H32047', 'g-wood')
    home = feed_home('g-belv')
    home.update_columns(catalog_plan_variant_id: other.id)
    variant('2856H32392', 'g-belv')
    home.update!(model: 'Aspire Belvidere 2')
    expect(home.reload.catalog_plan_variant_id).to eq(other.id)
  end
end
