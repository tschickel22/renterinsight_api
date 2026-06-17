# frozen_string_literal: true

require 'rails_helper'

# When a deal closes won on a vehicle, every OTHER open deal on that same
# vehicle should notify its rep (one notification per losing deal).
RSpec.describe NotifyHomeSoldOtherDealsService do
  let(:company) { Company.create!(name: "Co-#{SecureRandom.hex(4)}", industry: 'manufactured_housing') }
  let(:location) { company.locations.create!(name: 'Showroom', timezone: 'America/Denver') }
  let(:account) { company.accounts.create!(name: 'Buyer LLC') }

  def make_user
    company.users.create!(email: "u-#{SecureRandom.hex(4)}@ex.com", first_name: 'Rep',
                          last_name: SecureRandom.hex(2), password: 'Pass1234!', role: 'user')
  end

  let(:rep_a) { make_user }
  let(:rep_b) { make_user }

  def make_vehicle
    company.vehicles.create!(listing_type: 'manufactured_home', status: 'available', year: 2024,
                             make: 'Fleetwood', model: 'Aspire', serial_number: "SN-#{SecureRandom.hex(4)}",
                             bedrooms: 3, bathrooms: 2.0, sale_price: 70_000, dealer_cost: 50_000,
                             location_id: location.id)
  end

  def make_deal(vehicle:, owner: nil, primary_salesperson: nil, stage: 'qualification', name: 'Deal')
    company.deals.create!(name: "#{name}-#{SecureRandom.hex(2)}", vehicle: vehicle, location_id: location.id,
                          account: account, owner: owner, primary_salesperson: primary_salesperson,
                          stage: stage, customer_name: "Cust-#{SecureRandom.hex(2)}")
  end

  let(:unit) { make_vehicle }
  let(:won_deal) { make_deal(vehicle: unit, owner: rep_a, name: 'Winner') }

  def home_sold_notifications
    Notification.where(notification_type: 'home_sold_choose_new_home')
  end

  it 'notifies the rep on every other OPEN deal for the same vehicle, one per losing deal' do
    losing_a = make_deal(vehicle: unit, owner: rep_a, name: 'LosingA')
    losing_b = make_deal(vehicle: unit, owner: rep_b, name: 'LosingB')

    expect { won_deal.update!(stage: 'closed_won') }
      .to change { home_sold_notifications.count }.by(2)

    notes = home_sold_notifications.to_a
    expect(notes.map(&:recipient_id)).to match_array([rep_a.id, rep_b.id])
    # notifiable deep-links each rep to THEIR losing deal
    expect(notes.map { |n| [n.notifiable_type, n.notifiable_id] })
      .to match_array([['Deal', losing_a.id], ['Deal', losing_b.id]])
    expect(home_sold_notifications.find_by(recipient_id: rep_a.id).message)
      .to include('2024 Fleetwood Aspire', 'choose a new home')
  end

  it 'does not notify closed siblings or the won deal itself' do
    make_deal(vehicle: unit, owner: rep_b, stage: 'closed_lost', name: 'Lost')
    make_deal(vehicle: unit, owner: rep_b, stage: 'closed_won', name: 'OtherWon')

    expect { won_deal.update!(stage: 'closed_won') }
      .to change { home_sold_notifications.count }.by(0)
  end

  it 'falls back to primary_salesperson when the losing deal has no owner' do
    losing = make_deal(vehicle: unit, owner: rep_a, name: 'NoOwner')
    # Deal#sync_primary_salesperson forces primary_salesperson_id == owner_id on every
    # save, so set the divergent (owner nil, primary set) state directly via
    # update_columns to exercise the service's documented fallback branch.
    losing.update_columns(owner_id: nil, primary_salesperson_id: rep_b.id)

    expect { won_deal.update!(stage: 'closed_won') }
      .to change { home_sold_notifications.count }.by(1)
    expect(home_sold_notifications.last.recipient_id).to eq(rep_b.id)
  end

  it 'skips a losing deal with neither owner nor primary_salesperson' do
    make_deal(vehicle: unit, owner: nil, primary_salesperson: nil, name: 'Orphan')

    expect { won_deal.update!(stage: 'closed_won') }
      .to change { home_sold_notifications.count }.by(0)
  end

  it 'creates no notifications when the won deal has no vehicle' do
    no_vehicle = make_deal(vehicle: nil, owner: rep_a, name: 'NoVehicle')
    make_deal(vehicle: unit, owner: rep_b, name: 'OpenOnUnit')

    expect { no_vehicle.update!(stage: 'closed_won') }
      .to change { home_sold_notifications.count }.by(0)
  end

  it 'ignores open deals on a different vehicle' do
    other_unit = make_vehicle
    make_deal(vehicle: other_unit, owner: rep_b, name: 'OtherVehicle')
    make_deal(vehicle: unit, owner: rep_a, name: 'SameVehicle')

    expect { won_deal.update!(stage: 'closed_won') }
      .to change { home_sold_notifications.count }.by(1)
    expect(home_sold_notifications.last.recipient_id).to eq(rep_a.id)
  end
end
