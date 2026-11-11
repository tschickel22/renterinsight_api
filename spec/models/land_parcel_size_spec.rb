# frozen_string_literal: true

require 'rails_helper'

RSpec.describe LandParcel, 'size in acres or square feet' do
  let(:company) { Company.create!(name: "Co-#{SecureRandom.hex(4)}") }

  def parcel(attrs)
    described_class.create!({ company: company, status: 'available' }.merge(attrs))
  end

  it 'defaults to acres and fills square feet from them' do
    p = parcel(acreage: 2.5, price: 50_000)
    expect(p.size_unit).to eq('acres')
    expect(p.square_feet).to eq(108_900)
    expect(p.size_label).to eq('2.5 acres')
    expect(p.price_per_acre).to eq(20_000)
  end

  it 'takes square feet and works out acreage, so filters and price per acre still work' do
    p = parcel(size_unit: 'sq_ft', square_feet: 8_712, price: 30_000)
    expect(p.acreage).to eq(0.2)
    expect(p.size_label).to eq('8,712 sq ft')
    expect(p.price_per_sq_ft.to_f).to eq(3.44)
    expect(p.price_per_acre).to eq(150_000)
  end

  it 'keeps the typed unit when the other one is also sent' do
    p = parcel(size_unit: 'sq_ft', square_feet: 5_000, acreage: 9)
    expect(p.acreage.to_f).to eq(0.1148)
    expect(p.square_feet).to eq(5_000)
  end

  it 'switching an acre lot to square feet keeps its size' do
    p = parcel(acreage: 1)
    p.update!(size_unit: 'sq_ft')
    expect(p.reload.square_feet).to eq(43_560)
    expect(p.acreage).to eq(1)
    expect(p.size_label).to eq('43,560 sq ft')
  end

  it 'refuses an unknown unit' do
    expect { parcel(size_unit: 'hectares', acreage: 1) }.to raise_error(ActiveRecord::RecordInvalid)
  end
end
