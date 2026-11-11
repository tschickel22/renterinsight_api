# frozen_string_literal: true

require 'rails_helper'

# Base Sale Price (msrp) and the older sale_price column must not disagree when
# no Special Discount runs (Tom 2026-11-11).
RSpec.describe Vehicle, 'sale price follows the Base Sale Price' do
  let(:company) { Company.create!(name: "Dealer #{SecureRandom.hex(3)}") }

  def home(attrs = {})
    Vehicle.create!({ company: company, year: 2024, make: 'Skyline', model: 'Crest', vin: "VIN#{SecureRandom.hex(6).upcase}",
                      status: 'available', listing_type: 'manufactured_home', bedrooms: 3, bathrooms: 2 }.merge(attrs))
  end

  it 'moves a stale sale price to a new Base Sale Price' do
    v = home(msrp: 124_745, sale_price: 142_566)
    v.update!(msrp: 132_245)
    expect(v.reload.sale_price.to_f).to eq(132_245.0)
  end

  it 'leaves a home priced only by sale price alone' do
    v = home(sale_price: 90_000)
    v.update!(year: 2025)
    expect(v.reload.sale_price.to_f).to eq(90_000.0)
  end

  it 'keeps a sale price typed in the same save' do
    v = home(msrp: 100_000, sale_price: 100_000)
    v.update!(msrp: 110_000, sale_price: 105_000)
    expect(v.reload.sale_price.to_f).to eq(105_000.0)
  end

  it 'lets a running discount own the sale price' do
    v = home(msrp: 100_000, special_discount_enabled: true, discount_type: '% of Home Price', discount_value: 10)
    v.update!(msrp: 120_000)
    expect(v.reload.sale_price.to_f).to eq(108_000.0)
  end
end
