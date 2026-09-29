# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Catalog::ModelNumber do
  it 'decodes a Champion model number' do
    m = described_class.parse('2856H32392')

    expect(m).to be_valid
    expect([m.width_ft, m.length_ft, m.building_code, m.beds, m.baths, m.plan_code])
      .to eq([28, 56, 'HUD', 3, 2, '392'])
  end

  it 'keeps letters in plan codes' do
    expect(described_class.parse('2852M32A1C').plan_code).to eq('A1C')
  end

  it 'reads a scanned O as zero in the plan code only' do
    expect(described_class.normalize('1456h22po1')).to eq('1456H22P01')
    expect(described_class.normalize('1666H22P01')).to eq('1666H22P01')
  end

  it 'pairs the HUD and modular builds of one plan' do
    expect(described_class.parse('2856H32392').sibling_code).to eq('2856M32392')
    expect(described_class.parse('2856M32392').sibling_code).to eq('2856H32392')
  end

  it 'reports printed facts that disagree with the code' do
    # Champion prints 30' boxes as 32 in the code; the Prime scan lists Apex with 4 beds.
    conflicts = described_class.parse('3260M32181').conflicts_with(width_ft: 30, length_ft: 60, beds: 3)
    expect(conflicts).to eq([{ field: :width_ft, printed: 30, code: 32 }])

    expect(described_class.parse('2856H32PO1').conflicts_with(beds: 4, baths: 2))
      .to eq([{ field: :beds, printed: 4, code: 3 }])
  end

  it 'is invalid for anything that is not a model number' do
    expect(described_class.parse('Aspire Belvidere')).not_to be_valid
    expect(described_class.parse('Aspire Belvidere').conflicts_with(beds: 3)).to eq([])
  end
end
