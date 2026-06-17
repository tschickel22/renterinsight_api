# frozen_string_literal: true

require 'rails_helper'

RSpec.describe DealDesk::CompareService do
  let(:company) { create(:company) }
  let(:home_loc)  { company.locations.create!(name: 'Home Lot', timezone: 'America/Denver') }
  let(:other_loc) { company.locations.create!(name: 'Aurora Lot', timezone: 'America/Denver') }

  # Helper: a manufactured-home unit with the fields the compare service reads.
  def unit(serial:, location:, bedrooms: 3, bathrooms: 2.0, price:, cost:, days_old:, status: 'available')
    company.vehicles.create!(
      listing_type: 'manufactured_home', status: status,
      year: 2024, make: 'Fleetwood', model: 'Aspire', serial_number: serial,
      bedrooms: bedrooms, bathrooms: bathrooms,
      sale_price: price, dealer_cost: cost,
      location_id: location.id, date_in_stock: days_old.days.ago
    )
  end

  let!(:anchor)     { unit(serial: 'A',  location: home_loc,  price: 70_000, cost: 50_000, days_old: 30) }
  let!(:same_loc)   { unit(serial: 'B',  location: home_loc,  price: 68_000, cost: 48_000, days_old: 250) }
  let!(:cross_loc)  { unit(serial: 'C',  location: other_loc, price: 60_000, cost: 45_000, days_old: 300) }
  let!(:out_of_band) { unit(serial: 'D', location: home_loc,  price: 200_000, cost: 150_000, days_old: 100) }
  let!(:diff_bedbath) { unit(serial: 'E', location: home_loc, bedrooms: 2, bathrooms: 1.0, price: 69_000, cost: 49_000, days_old: 100) }

  let(:deal) { company.deals.build(vehicle: anchor, location_id: home_loc.id) }

  def candidate_ids(result)
    result[:candidates].map { |c| c[:vehicle_id] }
  end

  describe 'hard filter + price band + location scoping' do
    it 'matches bed/bath, applies the price band, and stays in the deal location by default' do
      result = described_class.new(company: company, deal: deal).call

      expect(candidate_ids(result)).to contain_exactly(same_loc.id)   # only the in-band, same-loc, matching unit
      expect(candidate_ids(result)).not_to include(anchor.id)         # anchor excluded
      expect(candidate_ids(result)).not_to include(out_of_band.id)    # price band excludes it
      expect(candidate_ids(result)).not_to include(diff_bedbath.id)   # hard bed/bath filter excludes it
      expect(candidate_ids(result)).not_to include(cross_loc.id)      # other location excluded by default
    end

    it 'reports the price band from the company setting' do
      band = described_class.new(company: company, deal: deal).call[:price_band]
      expect(band[:min]).to eq(55_000.0)  # 70,000 - 15,000
      expect(band[:max]).to eq(85_000.0)
    end
  end

  describe 'cross-location inclusion (deliberate exception)' do
    subject(:result) { described_class.new(company: company, deal: deal, include_other_locations: true).call }

    it 'includes the other-location unit when widened' do
      expect(candidate_ids(result)).to include(cross_loc.id)
    end

    it 'attaches location + days-on-lot + aged tier and flags cross-location' do
      row = result[:candidates].find { |c| c[:vehicle_id] == cross_loc.id }
      expect(row[:is_cross_location]).to be(true)
      expect(row[:location_name]).to eq('Aurora Lot')
      expect(row[:days_on_lot]).to be_within(2).of(300)
      expect(row[:aged_tier]).to eq(180)   # highest tier crossed
      expect(row[:is_aged]).to be(true)
    end

    it 'computes dealer gross (internal) from price minus cost' do
      row = result[:candidates].find { |c| c[:vehicle_id] == cross_loc.id }
      expect(row[:dealer_gross]).to eq(15_000.0)  # 60,000 - 45,000
    end
  end

  describe 'aged tiers' do
    it 'leaves a fresh unit untiered' do
      # anchor is 30 days old -> below the first (90-day) tier
      anchor_row = described_class.new(company: company, deal: deal).call[:anchor]
      expect(anchor_row[:aged_tier]).to be_nil
      expect(anchor_row[:is_aged]).to be(false)
    end
  end

  describe 'target-centered ranking' do
    # Pick a target only the cheaper cross-location unit meets, so the unit that hits the
    # customer's number outranks the higher-gross near-miss.
    subject(:result) do
      described_class.new(company: company, deal: deal, include_other_locations: true,
                          target_payment: target).call
    end

    let(:target) do
      # payment of the cross-location unit + a hair, so only it (and cheaper) "meets".
      DealDesk::Engine.compute(price: 60_000, apr: company.default_finance_rate, term_months: 180)
                      .monthly_payment + 1
    end

    it 'ranks the target-meeting aged cross-location unit first' do
      expect(result[:candidates].first[:vehicle_id]).to eq(cross_loc.id)
      expect(result[:candidates].first[:meets_target]).to be(true)
    end

    it 'still surfaces the near-miss unit, flagged as not meeting target' do
      miss = result[:candidates].find { |c| c[:vehicle_id] == same_loc.id }
      expect(miss[:meets_target]).to be(false)
    end
  end

  it 'raises when the deal has no anchor unit' do
    dealless = company.deals.build(location_id: home_loc.id)
    expect { described_class.new(company: company, deal: dealless).call }
      .to raise_error(ArgumentError, /no anchor unit/)
  end

  describe 'price resolution (msrp vs sale_price)' do
    # Regression: a candidate priced via msrp with NO sale_price (the common case —
    # sale_price is only populated when a special discount is enabled) was previously
    # read as $0, yielding a $0/mo payment and a negative gross equal to its cost.
    let!(:msrp_only) do
      company.vehicles.create!(
        listing_type: 'manufactured_home', status: 'available',
        year: 2026, make: 'Kabco', model: 'Madison', serial_number: 'MSRP1',
        bedrooms: 3, bathrooms: 2.0,
        msrp: 72_000, sale_price: nil, dealer_cost: 52_000,
        location_id: home_loc.id, date_in_stock: 40.days.ago
      )
    end

    it 'resolves a candidate price from msrp when sale_price is blank' do
      result = described_class.new(company: company, deal: deal).call
      row = result[:candidates].find { |c| c[:vehicle_id] == msrp_only.id }

      expect(row).not_to be_nil
      expect(row[:sale_price]).to eq(72_000.0)
      expect(row[:monthly_payment]).to be > 0
      expect(row[:dealer_gross]).to eq(20_000.0) # 72,000 - 52,000, never negative-cost
    end
  end

  describe 'anchor uses the deal negotiated price/cost' do
    # The anchor is this customer's real deal; its payment must match the deal, not raw
    # inventory. Persist a deal whose selling_price/unit_cost diverge from the unit.
    let(:negotiated_deal) do
      company.deals.create!(
        name: 'Negotiated', stage: 'negotiation', vehicle: anchor, location_id: home_loc.id,
        contact: company.contacts.create!(first_name: 'Pat', last_name: 'Buyer'),
        selling_price: 64_000, unit_cost: 51_000
      )
    end

    it 'centers the price band on the deal selling_price, not inventory sale_price' do
      band = described_class.new(company: company, deal: negotiated_deal).call[:price_band]
      expect(band[:center]).to eq(64_000.0)      # deal price, not the 70,000 inventory price
      expect(band[:min]).to eq(49_000.0)
      expect(band[:max]).to eq(79_000.0)
    end

    it 'computes the anchor row from the deal price/cost' do
      anchor_row = described_class.new(company: company, deal: negotiated_deal).call[:anchor]
      expect(anchor_row[:sale_price]).to eq(64_000.0)
      # Open deal => vehicle_landed_cost reads the LIVE vehicle structured_cost (dealer_cost
      # 50,000), which takes precedence over the unit_cost mirror. Gross = 64,000 - 50,000.
      expect(anchor_row[:dealer_gross]).to eq(14_000.0)
    end
  end
end
