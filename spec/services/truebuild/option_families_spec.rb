# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Truebuild::OptionFamilies do
  let(:option) { Struct.new(:id, :name) }

  def families(*names) = described_class.for(names.each_with_index.map { |n, i| option.new(i, n) })

  it 'groups options that differ only by fuel or package number' do
    expect(families('Stainless Steel Package - Electric', 'Stainless Steel Package - Gas').values.uniq.size).to eq(1)
    expect(families('Appliance Package 1 - Black', 'Appliance Package 2 - Black', 'Appliance Package A - Black').size).to eq(3)
    expect(families('PACKAGE 1', 'PACKAGE 3 (DRYWALL)').size).to eq(2)
  end

  it 'gives a kitchen one appliance package and one refrigerator, whichever line they come from' do
    fams = families('Appliance Package 1 - Black', 'Stainless Steel Package - Gas', 'Black Appliance Package - Electric',
                    'Ultimate Kitchen 2 (see Package Details) - Package 1 - Elec - French Door Refer', 'Dishwasher discount w/ Package #1')
    expect(fams.values.uniq).to eq(['appliance package'])
    expect(fams.keys).to eq([0, 1, 2, 3])

    fridges = families('20.5CF O/U Refer w/o Ice IPO 18.2', '24.7CF SS FrenchDoorRef IPO 18.2', '21.2 CF Black SxS Refer IPO 18.2CF',
                       '24.7CF SS FrenchDrRef IPO 20.5 O/U', 'Carpet IPO lino (per bdrm)', 'Carpet IPO lino (per LR)')
    expect(fridges.keys).to eq([0, 1, 2])
  end

  it 'leaves additive options, and lone members, alone' do
    expect(families('Crescent Edging - Kitchen', 'Crescent Edging - Utility')).to be_empty
    expect(families('Soft Close Drwrs & Doors - Baths', 'Soft Close Drwrs & Doors - Kit')).to be_empty
    expect(families('Stainless Steel Package - Gas', 'Decorator Pkg')).to be_empty
  end
end

RSpec.describe Truebuild::ColorSwatches do
  it 'names known finishes and falls back on words in the name' do
    expect(described_class.hex('Wedgewood')).to eq('#6f8394')
    expect(described_class.hex('Rum Cream (38oz)')).to eq('#d7cbb3')
    expect(described_class.hex('2 Rows Catch Ice (subway)')).to eq('#f3f3f0')
    expect(described_class.hex('Sunlit Maple')).to eq('#b58b5b')
    expect(described_class.hex('Mystery')).to be_nil
  end
end
