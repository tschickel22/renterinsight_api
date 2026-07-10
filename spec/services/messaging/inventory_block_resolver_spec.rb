# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Messaging::InventoryBlockResolver do
  let(:company) { Company.create!(name: "Co-#{SecureRandom.hex(3)}") }

  def make_vehicle(attrs = {})
    Vehicle.create!({
      company_id: company.id, year: 2024, make: 'Skyline', model: 'Aspen',
      status: 'available', listing_type: 'manufactured_home', sale_price: 89000,
      bedrooms: 3, bathrooms: 2,
      inventory_id: SecureRandom.hex(6),
      serial_number: SecureRandom.hex(8),
      vin: SecureRandom.hex(8)
    }.merge(attrs))
  end

  describe '#resolve' do
    it 'returns matching units in category_based mode' do
      v = make_vehicle
      result = described_class.new(config: { 'mode' => 'category_based' }, recipient: nil, company: company).resolve
      expect(result[:fallback_action]).to eq(:rendered)
      expect(result[:units].map { |u| u[:id] }).to include(v.id)
    end

    it 'filters by listing_type via static filters' do
      mh = make_vehicle(listing_type: 'manufactured_home', sale_price: 80000)
      rv = make_vehicle(listing_type: 'rv', sale_price: 50000, inventory_id: SecureRandom.hex(6),
                         vin: SecureRandom.hex(8))
      result = described_class.new(
        config: { 'mode' => 'category_based', 'filters' => { 'listing_type' => 'manufactured_home' } },
        recipient: nil, company: company
      ).resolve
      ids = result[:units].map { |u| u[:id] }
      expect(ids).to include(mh.id)
      expect(ids).not_to include(rv.id)
    end

    it 'segment_based applies recipient budget when use_recipient_budget=true' do
      cheap = make_vehicle(sale_price: 50000)
      pricey = make_vehicle(sale_price: 150000, inventory_id: SecureRandom.hex(6))
      recipient = Struct.new(:custom_field_values).new({ 'budget_max' => 75000 })
      result = described_class.new(
        config: { 'mode' => 'segment_based', 'segment_preferences' => { 'use_recipient_budget' => true } },
        recipient: recipient, company: company
      ).resolve
      ids = result[:units].map { |u| u[:id] }
      expect(ids).to include(cheap.id)
      expect(ids).not_to include(pricey.id)
    end

    it 'manual_pick respects manual_vehicle_ids' do
      v1 = make_vehicle
      v2 = make_vehicle(inventory_id: SecureRandom.hex(6))
      result = described_class.new(
        config: { 'mode' => 'manual_pick', 'manual_vehicle_ids' => [v1.id] },
        recipient: nil, company: company
      ).resolve
      expect(result[:units].map { |u| u[:id] }).to eq([v1.id])
    end

    it 'returns skip_block fallback when nothing matches' do
      result = described_class.new(
        config: { 'mode' => 'manual_pick', 'manual_vehicle_ids' => [999_999_999], 'fallback' => 'skip_block' },
        recipient: nil, company: company
      ).resolve
      expect(result[:units]).to eq([])
      expect(result[:fallback_action]).to eq(:skip_block)
    end

    it 'returns abort_send fallback when configured and empty' do
      result = described_class.new(
        config: { 'mode' => 'category_based', 'filters' => { 'listing_type' => 'never_matches' }, 'fallback' => 'abort_send' },
        recipient: nil, company: company
      ).resolve
      expect(result[:fallback_action]).to eq(:abort_send)
    end

    context 'when filters.location_ids is set' do
      let!(:loc_a) { Location.create!(company: company, name: 'A') }
      let!(:loc_b) { Location.create!(company: company, name: 'B') }
      let!(:at_a)  { make_vehicle(location_id: loc_a.id) }
      let!(:at_b)  { make_vehicle(location_id: loc_b.id, inventory_id: SecureRandom.hex(6), serial_number: SecureRandom.hex(8), vin: SecureRandom.hex(8)) }
      let!(:orderable) { make_vehicle(location_id: nil, status: 'available_to_order', inventory_id: SecureRandom.hex(6), serial_number: SecureRandom.hex(8), vin: SecureRandom.hex(8)) }

      it 'includes units at the specified locations' do
        result = described_class.new(
          config: { 'mode' => 'category_based', 'filters' => { 'location_ids' => [loc_a.id] } },
          recipient: nil, company: company
        ).resolve
        ids = result[:units].map { |u| u[:id] }
        expect(ids).to include(at_a.id)
        expect(ids).not_to include(at_b.id)
      end

      it 'also includes available_to_order units regardless of location' do
        result = described_class.new(
          config: { 'mode' => 'category_based', 'filters' => { 'location_ids' => [loc_a.id] } },
          recipient: nil, company: company
        ).resolve
        ids = result[:units].map { |u| u[:id] }
        expect(ids).to include(orderable.id) # orderable has location_id=nil but must not be dropped
      end

      it 'excludes orderable units when the caller narrows statuses to available only' do
        result = described_class.new(
          config: { 'mode' => 'category_based', 'filters' => { 'location_ids' => [loc_a.id], 'statuses' => ['available'] } },
          recipient: nil, company: company
        ).resolve
        ids = result[:units].map { |u| u[:id] }
        expect(ids).not_to include(orderable.id)
        expect(ids).to include(at_a.id)
      end
    end
  end
end
