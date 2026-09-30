# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Catalog::PriceBooks::Applicability do
  let(:series) { ['Aspire', 'Champion Genesis', 'Prime Of Indiana'] }

  def resolve(name, tab, ai = {}, **kw) = described_class.resolve(name: name, tab: tab, series_list: series, ai: ai, **kw)

  it 'takes the series from the tab, and a series with no plans reaches no home' do
    expect(resolve('Drywall Arch Passway', '2025 Aspire DW')['series']).to eq('Aspire')
    expect(resolve('Anything', 'Prime - Decatur factory')['series']).to eq('Prime Of Indiana')
    expect(resolve('Anything', '2023 DGAE HUD')['series']).to eq('Dgae')
    expect(resolve('Anything', 'DIAMOND Model Specific')['series']).to eq('Diamond')
    expect(resolve('Anything', 'Master Option List')['series']).to be_nil
    expect(resolve('Porch', 'ASPIRE MODEL SPECIFIC OPTS', model_specific: true)['series']).to be_nil
  end

  it 'trusts the tab over the name over the model for section type, and never reads DW in a name as double wide' do
    expect(resolve("Drywall T/O - Sect 48-56' Box", '2025 Aspire DW', { 'section_type' => 'single' })['section_type']).to eq('multi')
    expect(resolve('3" White Int Trim T/O - Drywall - SW', '2023 DGAE HUD')['section_type']).to eq('single')
    expect(resolve('OSB IPO Red Board - Sectional', '2023 DGAE HUD')['section_type']).to eq('multi')
    expect(resolve('Full Red Board Wrap (Partial DW)', '2023 DGAE HUD', { 'section_type' => 'single' })['section_type']).to eq('single')
    expect(resolve('Drywall Arch Passway', '2023 DGAE HUD')['section_type']).to be_nil
  end

  it 'reads length bands from the name and drops impossible widths' do
    expect(resolve("Drywall T/O - Sect 48-56' Box", 't')).to include('min_length_ft' => 48, 'max_length_ft' => 56)
    expect(resolve("Drywall T/O - Sect <48' Box", 't')).to include('min_length_ft' => nil, 'max_length_ft' => 47)
    expect(resolve("Drywall T/O SW<=60' box", 't', { 'width_ft' => 60 })).to include('max_length_ft' => 60, 'width_ft' => nil)
    expect(resolve("Drywall T/O SW >60' box", 't')).to include('min_length_ft' => 61, 'max_length_ft' => nil)
    expect(resolve('Knobs', 't', { 'box_length_min_ft' => 40, 'width_ft' => 16 })).to include('min_length_ft' => 40, 'width_ft' => 16)
  end

  it 'keeps options that differ only by a comparison apart' do
    keys = Catalog::PriceBooks::Keys
    expect(keys.option('Drywall', "Drywall T/O SW<=60' box")).not_to eq(keys.option('Drywall', "Drywall T/O SW >60' box"))
  end
end
