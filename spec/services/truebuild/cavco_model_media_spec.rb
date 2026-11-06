# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Truebuild::CavcoModelMedia do
  let(:mfr) { Manufacturer.create!(name: "Cavco #{SecureRandom.hex(3)}", industry_type: 'manufactured_home') }
  let(:factory) { mfr.factories.create!(name: 'Plant City', code: "PC#{SecureRandom.hex(2)}") }
  let!(:source) do
    CatalogSource.create!(name: "Cavco plant 34 #{SecureRandom.hex(2)}", adapter_type: 'cavco_plant', base_url: 'https://www.cavcohomes.com',
                          config: { 'plant' => { 'id' => '34' }, 'factory_id' => factory.id })
  end

  def variant(series, name, number, w = 28, l = 60)
    plan = CatalogPlan.create!(manufacturer: mfr, factory: factory, series: series, name: name)
    CatalogPlanVariant.create!(catalog_plan: plan, manufacturer: mfr, model_number: number, width_ft: w, length_ft: l, building_code: 'HUD')
  end

  def doc(id, name, number, series, photos)
    { 'id' => id, 'name' => name, 'model_number' => number, 'series' => series,
      'photos' => photos.map { |f| { 'url' => "https://cdn2.cavco.com/public/phhweb/#{f}" } }.to_json,
      'line_drawings' => [{ 'url' => "https://cdn2.cavco.com/public/phhweb/#{id}_plan.jpg" }].to_json }
  end

  let(:docs) do
    [doc('d1', 'Ashley', '28603A', 'Elite', %w[26_340_ashley_el28603a_kitchen_001_web_1.jpg 26_340_ashley_el28603a_exterior_001_render_1.jpg
                                              26_340_ashley_el28603a_livingroom_002_web_1.jpg]),
     doc('d2', 'Craft Select', '28603A', 'Craft Select', %w[340cs28603a_rf0_621_10.jpg]),
     doc('d3', 'Roanoke', 'Duplex', 'Anthem', %w[23_fw_270_anthem_theroanoke_bath_013.jpg]),
     doc('d4', 'Eagle', '11341A', 'Eagle', %w[chariot_eagle_eagle_eg12341a_kit_0319_1.jpg chariot_eagle_eagle_eg12341a_bunks_0581_1.jpg])]
  end

  before do
    adapter = instance_double(Catalog::Adapters::CavcoPlantAdapter, discover: docs.map { |d| d['id'] })
    allow(adapter).to receive(:fetch) { |id| docs.find { |d| d['id'] == id } }
    allow(Catalog::AdapterRegistry).to receive(:for).and_call_original
    allow(Catalog::AdapterRegistry).to receive(:for).with(source).and_return(adapter)
  end

  it 'links a shared number only where the name or series agrees, and rooms from file names' do
    ashley = variant('Elite', 'Ashley', '28603A')
    craft = variant('Craft Select', 'Craft Select 28603A', '28603A')
    ellenton = variant('Lifestyle', 'Ellenton', '28603A')

    result = described_class.refresh!(mfr)

    expect(ashley.reload.media['photos'].map { |p| p['room'] }).to eq(%w[kitchen exterior living])
    expect(ashley.media['floor_plans']).to eq(['https://cdn2.cavco.com/public/phhweb/d1_plan.jpg'])
    expect(ashley.external_ids['cavco_floorplan_id']).to eq('d1')
    expect(craft.reload.media['photos'].first['room']).to eq('exterior')
    expect(ellenton.reload.media).to be_blank
    expect(result[:unmatched]).to include('28603A')
  end

  it 'links a model with no number by name, and a unique number on its own' do
    roanoke = variant('Anthem', 'Roanoke Duplex', 'ROANOKEDUPLEX', 15, 76)
    eagle = variant('Eagle Loft', 'Eagle', '11341A', 11, 34)

    described_class.refresh!(mfr)

    expect(roanoke.reload.media['photos'].first).to include('room' => 'bath')
    expect(eagle.reload.media['photos'].map { |p| p['room'] }).to eq(%w[kitchen bedroom])
  end

  it 'keeps what an admin chose for TrueView' do
    ashley = variant('Elite', 'Ashley', '28603A')
    ashley.update_columns(media: { 'trueview_photos' => { 'kitchen' => ['x'] } })

    described_class.refresh!(mfr)

    expect(ashley.reload.media['trueview_photos']).to eq('kitchen' => ['x'])
    expect(ashley.media['photos']).to be_present
  end

  it 'leaves plants it does not feed alone' do
    other = mfr.factories.create!(name: 'Ocala', code: "OC#{SecureRandom.hex(2)}")
    plan = CatalogPlan.create!(manufacturer: mfr, factory: other, series: 'Elite', name: 'Ashley')
    v = CatalogPlanVariant.create!(catalog_plan: plan, manufacturer: mfr, model_number: '28603A', building_code: 'HUD')

    described_class.refresh!(mfr)

    expect(v.reload.media).to be_blank
  end
end
