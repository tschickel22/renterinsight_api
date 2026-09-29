# frozen_string_literal: true

require 'rails_helper'

# Agreement formulas read deal and home data directly and total line items, so
# a purchase agreement's subtotals come from the deal instead of retyped copies.
RSpec.describe FormulaEngine, 'merge fields and line items' do
  let(:engine) { described_class.new }
  let(:deal) do
    {
      'deal.selling_price' => '87489',
      'deal.line_items_accessory[0].line_total' => '179',
      'deal.line_items_accessory[1].line_total' => '$1,240.00',
      'deal.line_items_accessory[2].line_total' => '',
      'deal.line_items_fee[0].line_total' => '495'
    }
  end

  it 'reads merge fields next to template fields' do
    defs = [{ 'key' => 'sub_total_1', 'formula' => '=deal.selling_price - factory_direct_savings' }]

    expect(engine.evaluate(defs, { 'factory_direct_savings' => '8425' }, deal)).to eq('sub_total_1' => 79_064.0)
  end

  it 'sums a line-item column across every row, skipping blanks and reading typed amounts' do
    defs = [{ 'key' => 'addendum_total', 'formula' => '=sum(deal.line_items_accessory.line_total)' }]

    expect(engine.evaluate(defs, {}, deal)).to eq('addendum_total' => 1419.0)
  end

  it 'sums several arguments' do
    defs = [{ 'key' => 't', 'formula' => '=sum(deal.line_items_accessory.line_total, deal.line_items_fee.line_total, 1)' }]

    expect(engine.evaluate(defs, {}, deal)).to eq('t' => 1915.0)
  end

  it 'lets a template value override the same key from the deal' do
    defs = [{ 'key' => 'x', 'formula' => '=deal.selling_price' }]

    expect(engine.evaluate(defs, { 'deal.selling_price' => '90000' }, deal)).to eq('x' => 90_000.0)
  end

  it 'chains formulas that depend on a sum' do
    defs = [
      { 'key' => 'upgrades', 'formula' => '=sum(deal.line_items_accessory.line_total)' },
      { 'key' => 'total', 'formula' => '=deal.selling_price + upgrades' }
    ]

    expect(engine.evaluate(defs, {}, deal)).to include('total' => 88_908.0)
  end

  it 'treats a deal with no rows as zero' do
    defs = [{ 'key' => 't', 'formula' => '=sum(deal.line_items_land.line_total)' }]

    expect(engine.evaluate(defs, {}, deal)).to eq('t' => 0.0)
  end

  describe '#validate_formula' do
    it 'accepts merge field references' do
      result = engine.validate_formula('=deal.selling_price + sum(deal.line_items_fee.line_total) - disc', ['disc'])

      expect(result[:valid]).to be(true)
    end

    it 'still rejects unknown template fields' do
      expect(engine.validate_formula('=bogus + 1', ['disc'])).to include(valid: false)
    end
  end
end
