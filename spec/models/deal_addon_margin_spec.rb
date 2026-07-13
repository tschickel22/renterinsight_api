# frozen_string_literal: true

require 'rails_helper'

# Pins down which line-item categories feed front-end add-on margin / add-on gross.
#
# History: earlier the classifier only matched `category:fee` and `category:accessory`,
# which silently dropped `category:service` — the exact tag the FE hardcodes on every
# "standard item" allowance (Trim Out, Delivery & Set, Skirting, AC, Water Hookup, etc.).
# Every MH deal with an allowance add-on was under-reporting Front Gross by the sum of
# those margins. This spec locks the widened classifier in.
RSpec.describe 'Deal front-end add-on classification', type: :model do
  let(:company) { Company.create!(name: "Co-#{SecureRandom.hex(4)}", industry: 'manufactured_housing') }
  let(:location) { company.locations.create!(name: 'Showroom', timezone: 'America/Denver') }
  let(:account) { company.accounts.create!(name: 'Buyer LLC') }
  let(:vehicle) do
    company.vehicles.create!(listing_type: 'manufactured_home', status: 'available', year: 2024,
                             make: 'Kabco', model: 'MDPG', serial_number: "SN-#{SecureRandom.hex(4)}",
                             bedrooms: 3, bathrooms: 2.0, sale_price: 174_990, dealer_cost: 112_876,
                             location_id: location.id, date_in_stock: 30.days.ago)
  end
  let(:deal) { company.deals.create!(name: 'Test Deal', account: account, vehicle: vehicle, location_id: location.id) }

  def add_line(category:, price:, cost:, name: 'Item', qty: 1)
    deal.deal_products.create!(product_name: name, unit_price: price, cost: cost, quantity: qty,
                               notes: "category:#{category}")
  end

  before do
    # Home line establishes the base — its margin flows through selling_price/landed_cost,
    # not front_end_addon_margin. Add-on classifier must skip it.
    add_line(category: 'home', name: '2024 Kabco', price: 174_990, cost: 112_876)
  end

  describe '#front_end_addon_margin' do
    it 'includes category:service (allowance items — the previously-dropped bug)' do
      add_line(category: 'service', name: 'Trim Out', price: 8_999, cost: 900)
      expect(deal.reload.front_end_addon_margin).to eq(8_099.0)
    end

    it 'includes category:fee' do
      add_line(category: 'fee', name: 'Delivery Fee', price: 2_000, cost: 500)
      expect(deal.reload.front_end_addon_margin).to eq(1_500.0)
    end

    it 'includes category:accessory' do
      add_line(category: 'accessory', name: 'Deck', price: 1_500, cost: 800)
      expect(deal.reload.front_end_addon_margin).to eq(700.0)
    end

    it 'includes category:other (custom lines the rep adds)' do
      add_line(category: 'other', name: 'Custom Item', price: 500, cost: 100)
      expect(deal.reload.front_end_addon_margin).to eq(400.0)
    end

    it 'includes category:land' do
      add_line(category: 'land', name: 'Lot Prep', price: 3_000, cost: 1_000)
      expect(deal.reload.front_end_addon_margin).to eq(2_000.0)
    end

    it 'excludes category:home (base — margin handled elsewhere)' do
      expect(deal.reload.front_end_addon_margin).to eq(0.0)
    end

    it 'excludes category:product (F&I — belongs to back_gross)' do
      add_line(category: 'product', name: 'GAP', price: 900, cost: 200)
      expect(deal.reload.front_end_addon_margin).to eq(0.0)
    end

    it 'multiplies by quantity' do
      add_line(category: 'service', name: 'Steps', price: 800, cost: 400, qty: 2)
      # (800 - 400) * 2 = 800
      expect(deal.reload.front_end_addon_margin).to eq(800.0)
    end

    it 'sums a mixed batch (mirrors the Evangeline shape)' do
      add_line(category: 'service', name: 'Trim Out',       price: 8_999, cost: 900)
      add_line(category: 'fee',     name: 'Delivery Fee',   price: 2_000, cost: 0)
      add_line(category: 'product', name: 'Extended Warr.', price: 3_500, cost: 1_000) # excluded
      expect(deal.reload.front_end_addon_margin).to eq(8_099.0 + 2_000.0)
    end
  end

  describe '#addon_gross (revenue)' do
    it 'sums revenue on service/fee/accessory/land/other; excludes home + product' do
      add_line(category: 'service', name: 'Trim Out',   price: 8_999, cost: 900)
      add_line(category: 'fee',     name: 'Setup Fee',  price: 2_000, cost: 0)
      add_line(category: 'product', name: 'GAP',        price: 900,   cost: 200) # excluded
      # 8999 + 2000
      expect(deal.reload.addon_gross).to eq(10_999.0)
    end

    it 'excludes doc fee (it is a pass-through, not commissionable add-on)' do
      add_line(category: 'fee', name: 'Doc Fee', price: 300, cost: 0)
      expect(deal.reload.addon_gross).to eq(0.0)
    end
  end
end
