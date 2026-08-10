# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Reports::CostVisibility do
  let(:report) do
    {
      period: { start_date: Date.new(2026, 1, 1), end_date: Date.new(2026, 12, 31) },
      deals: [
        {
          deal_id: 1, deal_title: 'Unit 12', selling_price: 120_000,
          landed_cost: 90_000, cost_entered: true, front_gross: 30_000,
          commissionable_front_gross: 28_000, back_gross: 4_000, total_gross: 34_000,
          commission: 3_000, carrying_costs: 500, net_profit: 30_500,
          front_detail: { vehicle_cost: 88_000, recon: 2_000 }
        }
      ],
      summary: {
        total_revenue: 120_000, total_front_gross: 30_000, total_back_gross: 4_000,
        total_gross_profit: 34_000, total_commission: 3_000, total_net_profit: 30_500,
        gross_margin: 28.33
      }
    }
  end

  context 'when the viewer may see cost' do
    it 'hands the report back untouched' do
      expect(described_class.apply(report, can_view_costs: true)).to eq(report)
    end
  end

  context 'when the viewer may not see cost' do
    subject(:scrubbed) { described_class.apply(report, can_view_costs: false) }

    it 'removes what the dealership paid and what it made' do
      row = scrubbed[:deals].first

      expect(row).not_to include(:landed_cost, :front_gross, :back_gross, :total_gross,
                                 :net_profit, :carrying_costs, :front_detail,
                                 :commissionable_front_gross)
    end

    # A sales rep should still see which deals closed and for how much. Hiding
    # the whole report would be a blunter instrument than the situation needs.
    it 'keeps the deal and its selling price' do
      row = scrubbed[:deals].first

      expect(row[:deal_id]).to eq(1)
      expect(row[:deal_title]).to eq('Unit 12')
      expect(row[:selling_price]).to eq(120_000)
    end

    it 'removes the margin totals but keeps revenue' do
      expect(scrubbed[:summary]).not_to include(:total_front_gross, :total_back_gross,
                                                :total_gross_profit, :total_net_profit,
                                                :gross_margin)
      expect(scrubbed[:summary][:total_revenue]).to eq(120_000)
    end

    # Removed rather than nulled: a nil renders as zero margin in most tables,
    # which is a worse lie than an absent column.
    it 'removes the keys rather than nulling them' do
      expect(scrubbed[:deals].first.key?(:landed_cost)).to be false
    end

    it 'says so, so a client can label the gap' do
      expect(scrubbed[:can_view_costs]).to be false
    end

    it 'leaves the original untouched' do
      scrubbed
      expect(report[:deals].first).to include(:landed_cost)
    end
  end

  it 'tolerates a report with no deals or summary' do
    expect { described_class.apply({ period: {} }, can_view_costs: false) }.not_to raise_error
  end
end
