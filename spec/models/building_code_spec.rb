# frozen_string_literal: true

require 'rails_helper'

# Every feed words the build differently. These are the exact strings each one
# publishes (checked against the live feeds on 2026-10-09), so a dealer's
# Modular page finds modular homes whichever builder they came from.
RSpec.describe BuildingCode do
  describe '.from_label' do
    {
      # Champion IMS buildingCode.code
      'HUD' => 'HUD', 'MOD' => 'MOD', 'ANSI' => 'ANSI', 'HUD or MOD' => 'HUD_MOD',
      # Cavco building_method
      'Manufactured' => 'HUD', 'Modular' => 'MOD', 'Modular or Manufactured' => 'HUD_MOD',
      'Park Model' => 'ANSI', 'Manufactured Duplex' => 'HUD', 'Modular Duplex' => 'MOD',
      'Modular Multi-family' => 'MOD',
      # Our Home Type picklist and the codes themselves
      'Modular Home' => 'MOD', 'Manufactured Home' => 'HUD', 'hud' => 'HUD', 'mod' => 'MOD',
      'HUD_MOD' => 'HUD_MOD'
    }.each do |label, code|
      it("reads #{label.inspect} as #{code}") { expect(described_class.from_label(label)).to eq(code) }
    end

    # A size is not a code. Guessing HUD from "Double Wide" would put a modular
    # double wide on the wrong page.
    ['Single Wide', 'Double Wide', 'Tiny Home', 'Other', '', nil].each do |label|
      it("says nothing for #{label.inspect}") { expect(described_class.from_label(label)).to be_nil }
    end
  end

  it 'takes the first label that names a code (Cavco sends size, then method)' do
    expect(described_class.from_labels(['Double Wide', 'Modular'])).to eq('MOD')
  end

  describe '.matching' do
    it 'puts a home built either way on the Modular page and the HUD page' do
      expect(described_class.matching(['MOD'])).to match_array(%w[MOD HUD_MOD])
      expect(described_class.matching('HUD')).to match_array(%w[HUD HUD_MOD])
    end

    it 'keeps a park model page to park models' do
      expect(described_class.matching(['ANSI'])).to eq(['ANSI'])
    end

    it 'matches nothing for a code it does not know, rather than everything' do
      expect(described_class.matching(['bogus'])).to eq([])
    end
  end

  describe 'on a vehicle' do
    let(:company) { create(:company) }

    def home(attrs)
      Vehicle.create!({ company: company, year: 2025, make: 'Clayton', model: 'Tide',
                        vin: "VIN#{SecureRandom.hex(6).upcase}", status: 'available' }.merge(attrs))
    end

    it 'stores the code when an import sends the word' do
      expect(home(building_code: 'Modular').building_code).to eq('MOD')
    end

    it 'takes the code from a Home Type that states it' do
      expect(home(home_type: 'Park Model').building_code).to eq('ANSI')
    end

    it 'leaves a code the dealer chose alone when Home Type disagrees' do
      expect(home(home_type: 'Modular Home', building_code: 'HUD').building_code).to eq('HUD')
    end
  end
end
