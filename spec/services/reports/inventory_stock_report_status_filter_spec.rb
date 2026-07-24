# frozen_string_literal: true

require 'rails_helper'
require 'ostruct'

# Chunk 2: the stock report body is driven by a multi-select status filter that
# defaults to hiding available_to_order + sold, while preserving the sold-with-a-
# deal dedup against the Closed/Funded section.
RSpec.describe Reports::InventoryStockReportService, type: :service do
  let(:company) { Company.create!(name: "Co-#{SecureRandom.hex(4)}") }
  let(:service) { described_class.new(company) }

  def selected_with(filters)
    service.instance_variable_set(:@filters, filters)
    service.send(:selected_statuses)
  end

  def included?(status:, sold_via_deal_id: nil, open_deals: [], selected:)
    v = OpenStruct.new(status: status, sold_via_deal_id: sold_via_deal_id)
    service.send(:included_in_body?, v, open_deals, selected)
  end

  describe 'default status selection' do
    it 'excludes available_to_order and sold, includes the rest (incl. new statuses)' do
      sel = selected_with({})
      expect(sel).not_to include('available_to_order')
      expect(sel).not_to include('sold')
      expect(sel).to include('available', 'reserved', 'pending', 'ordered', 'on_order', 'rso', 'trade_in')
    end

    it 'honors an explicit statuses list (CSV or array)' do
      expect(selected_with(statuses: 'sold,ordered')).to eq(Set['sold', 'ordered'])
      expect(selected_with(statuses: %w[available])).to eq(Set['available'])
    end
  end

  describe 'included_in_body?' do
    let(:default) { selected_with({}) }

    it 'shows a plain available unit by default' do
      expect(included?(status: 'available', selected: default)).to be(true)
    end

    it 'hides sold and available_to_order by default' do
      expect(included?(status: 'sold', selected: default)).to be(false)
      expect(included?(status: 'available_to_order', selected: default)).to be(false)
    end

    it 'shows a unit with an open deal regardless of status selection' do
      expect(included?(status: 'sold', open_deals: [double], selected: default)).to be(true)
    end

    it 'shows sold-with-no-deal when sold is selected, but keeps sold-with-a-deal out (Closed/Funded dedup)' do
      expect(included?(status: 'sold', sold_via_deal_id: nil, selected: Set['sold'])).to be(true)
      expect(included?(status: 'sold', sold_via_deal_id: 42, selected: Set['sold'])).to be(false)
    end

    it 'surfaces available_to_order (catalog) when explicitly selected' do
      expect(included?(status: 'available_to_order', sold_via_deal_id: nil, selected: Set['available_to_order'])).to be(true)
    end
  end
end
