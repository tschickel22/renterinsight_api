# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Truebuild::Trueview::OptionLook do
  it 'reads the style, finish and dispenser an order form abbreviates' do
    # A top-freezer's "w/ Ice" is an ice maker inside, so nothing about a dispenser either way.
    expect(described_class.describe('Refrigerator', '20.5CF O/U Refer w/o Ice IPO 18.2'))
      .to eq('top-freezer refrigerator (a freezer door on top of a larger fresh food door)')
    expect(described_class.describe('Refrigerator', '20.5CF O/U Refer w/ Ice IPO 18.2'))
      .to eq('top-freezer refrigerator (a freezer door on top of a larger fresh food door)')
    expect(described_class.describe('Refrigerator', '21 CF Stnls SxS Refer w/ice IPO 18.2CF'))
      .to eq('stainless steel side-by-side refrigerator (two tall doors side by side, freezer on one side) with an ice and water dispenser on the door')
    expect(described_class.describe('Refrigerator', '24.7CF SS FrenchDoorRef IPO 18.2')).to start_with('stainless steel French door refrigerator')
    expect(described_class.describe('Appliances', 'Black Stainless Steel Package - Electric')).to eq('black stainless steel appliances')
    expect(described_class.describe('Appliances', 'Appliance Package 1 - Black')).to eq('black appliances')
  end

  it 'says nothing for a finish that is not an appliance, or a name that promises no look' do
    expect(described_class.describe('Cabinets', 'Destin White')).to be_nil
    expect(described_class.describe('Appliances', 'Ultimate Kitchen 2 - Package 1')).to be_nil
  end
end
