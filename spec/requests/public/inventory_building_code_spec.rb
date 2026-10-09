# frozen_string_literal: true

require 'rails_helper'

# A dealer who sells HUD and modular homes wants a Modular page on their site.
# The inventory block locks the page to the codes it names (building_codes);
# a visitor can narrow further with the Construction filter (building_code).
RSpec.describe 'Public inventory building codes', type: :request do
  let(:company) do
    create(:company).tap do |c|
      c.update!(public_inventory_token: SecureRandom.hex(8),
                public_inventory_settings: { 'public_inventory_enabled' => true })
    end
  end

  def home(model, code)
    Vehicle.create!(company: company, year: 2025, make: 'Clayton', model: model, building_code: code,
                    vin: "VIN#{SecureRandom.hex(6).upcase}", status: 'available', is_deleted: false)
  end

  def get_json(path, params = {})
    get path, params: { token: company.public_inventory_token, company_id: company.id }.merge(params)
    JSON.parse(response.body)
  end

  def models(params = {}) = get_json('/public/inventory', params)['items'].map { |i| i['model'] }

  before do
    home('Hud', 'HUD')
    home('Mod', 'MOD')
    home('Either', 'HUD_MOD')
    home('Park', 'ANSI')
    home('Unknown', nil)
  end

  it 'shows a Modular page modular homes and homes built either way' do
    expect(models(building_codes: 'MOD')).to match_array(%w[Mod Either])
  end

  it 'lets one block show several codes' do
    expect(models(building_codes: 'MOD,ANSI')).to match_array(%w[Mod Either Park])
  end

  it 'narrows a locked page by what the visitor picks, never widening it' do
    expect(models(building_codes: 'MOD', building_code: 'HUD')).to eq(%w[Either])
  end

  it 'leaves the listing alone when nothing is asked' do
    expect(models.size).to eq(5)
  end

  it 'publishes the code on each home' do
    item = get_json('/public/inventory', building_codes: 'ANSI')['items'].first
    expect(item.values_at('building_code', 'building_code_label')).to eq(['ANSI', 'Park Model (ANSI)'])
  end

  describe 'filter options' do
    it 'offers the codes on the lot, labelled and counted' do
      codes = get_json('/public/inventory/filters')['building_codes']
      expect(codes.map { |c| c['value'] }).to eq(%w[HUD MOD ANSI HUD_MOD])
      expect(codes.first).to include('label' => 'Manufactured (HUD)', 'count' => 1)
    end

    it 'offers only what a locked page can show' do
      data = get_json('/public/inventory/filters', building_codes: 'MOD')
      expect(data['building_codes'].map { |c| c['value'] }).to match_array(%w[MOD HUD_MOD])
      expect(data['total_count']).to eq(2)
    end
  end
end
