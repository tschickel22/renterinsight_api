# frozen_string_literal: true

require 'rails_helper'

# Covers the dispatch "deal close -> vehicle sold (with auto-revert)" commit.
# The service is unit-tested in isolation by assigning deal.stage in memory (no save,
# so the after_save callback does not also fire); a final integration test exercises the
# real Deal wiring (previous_stage derived from saved_change_to_stage).
RSpec.describe DealVehicleStatusSync do
  let(:company) { Company.create!(name: "Co-#{SecureRandom.hex(4)}", industry: 'manufactured_housing') }
  let(:account) { company.accounts.create!(name: 'Buyer LLC') }

  def vehicle(status: 'available', **over)
    company.vehicles.create!(listing_type: 'manufactured_home', status: status, year: 2024,
                             make: 'Fleetwood', model: 'Aspire', serial_number: "SN-#{SecureRandom.hex(4)}",
                             bedrooms: 3, bathrooms: 2.0, sale_price: 70_000, **over)
  end

  def deal_for(veh, stage:)
    company.deals.create!(name: 'Deal', account: account, vehicle: veh, stage: stage)
  end

  describe '.call (in isolation)' do
    it 'marks the vehicle sold when the deal transitions INTO closed_won' do
      veh = vehicle
      deal = deal_for(veh, stage: 'negotiation')
      deal.stage = 'closed_won' # assign only — no save

      described_class.call(deal, previous_stage: 'negotiation')

      veh.reload
      expect(veh.status).to eq('sold')
      expect(veh.sold_via_deal_id).to eq(deal.id)
      expect(veh.sold_at).to be_present
    end

    it 'reverts the vehicle when the deal transitions OUT of closed_won (and this deal owns it)' do
      veh = vehicle(status: 'available')
      deal = deal_for(veh, stage: 'negotiation')
      veh.update!(status: 'sold', sold_at: Time.current, sold_via_deal_id: deal.id)
      deal.stage = 'closed_lost'

      described_class.call(deal, previous_stage: 'closed_won')

      veh.reload
      expect(veh.status).to eq('available')
      expect(veh.sold_via_deal_id).to be_nil
      expect(veh.sold_at).to be_nil
    end

    it 'does NOT re-attribute a vehicle already sold via a different deal' do
      veh = vehicle
      other_deal = deal_for(veh, stage: 'closed_won')
      veh.update!(status: 'sold', sold_at: Time.current, sold_via_deal_id: other_deal.id)

      deal = deal_for(veh, stage: 'negotiation')
      deal.stage = 'closed_won'
      described_class.call(deal, previous_stage: 'negotiation')

      veh.reload
      expect(veh.sold_via_deal_id).to eq(other_deal.id) # unchanged — not stolen
    end

    it 'does NOT revert a vehicle owned by a different deal' do
      veh = vehicle
      owner_deal = deal_for(veh, stage: 'closed_won')
      veh.update!(status: 'sold', sold_at: Time.current, sold_via_deal_id: owner_deal.id)

      other = deal_for(veh, stage: 'closed_won')
      other.stage = 'closed_lost'
      described_class.call(other, previous_stage: 'closed_won')

      veh.reload
      expect(veh.status).to eq('sold')
      expect(veh.sold_via_deal_id).to eq(owner_deal.id)
    end

    it 'is a no-op for stage changes that do not involve closed_won' do
      veh = vehicle
      deal = deal_for(veh, stage: 'qualification')
      deal.stage = 'proposal'

      expect { described_class.call(deal, previous_stage: 'qualification') }
        .not_to(change { veh.reload.status })
    end

    it 'is a no-op when the deal has no linked vehicle' do
      deal = company.deals.create!(name: 'No unit', account: account, stage: 'negotiation')
      deal.stage = 'closed_won'
      expect { described_class.call(deal, previous_stage: 'negotiation') }.not_to raise_error
    end
  end

  describe 'Deal wiring (previous_stage derived from saved change)' do
    it 'marks sold on close and reverts on reopen via the after_save callback' do
      veh = vehicle
      deal = deal_for(veh, stage: 'negotiation')

      deal.update!(stage: 'closed_won')
      expect(veh.reload.status).to eq('sold')
      expect(veh.sold_via_deal_id).to eq(deal.id)

      deal.update!(stage: 'negotiation') # reopen
      expect(veh.reload.status).to eq('available')
      expect(veh.sold_via_deal_id).to be_nil
    end
  end
end
