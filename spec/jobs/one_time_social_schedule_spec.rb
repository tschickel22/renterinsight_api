# frozen_string_literal: true

require 'rails_helper'

# A one_time schedule exists so a user can queue a single post for later. It
# fires once at run_at, publishes without an approval round-trip, and retires
# itself rather than recurring.
RSpec.describe GenerateScheduledSocialPostsJob, 'one_time schedules' do
  let(:company) { Company.create!(name: "C-#{SecureRandom.hex(4)}", industry: 'manufactured_housing') }

  let(:vehicle) do
    company.vehicles.create!(
      inventory_id: "INV-#{SecureRandom.hex(4)}",
      listing_type: 'manufactured_home',
      serial_number: "SN-#{SecureRandom.hex(4)}",
      year: 2024, make: 'Clayton', model: 'Breeze',
      bedrooms: 3, bathrooms: 2, status: 'available',
      photo_url: 'https://x/unit.jpg'
    )
  end

  def one_time(**attrs)
    company.social_post_schedules.create!(
      frequency: 'one_time', run_at: 1.hour.ago,
      intent_rotation: ['specific_unit'], require_vehicle: false, **attrs
    )
  end

  before do
    allow(SocialPostGeneratorService).to receive(:generate).and_return(
      { caption: 'Generated.', cta_type: 'shop_now' }
    )
    allow(PublishSocialPostJob).to receive(:perform_later)
  end

  describe 'validation and timing' do
    it 'requires a run_at' do
      schedule = company.social_post_schedules.new(frequency: 'one_time')
      expect(schedule).not_to be_valid
      expect(schedule.errors[:run_at]).to be_present
    end

    it 'schedules itself for exactly run_at rather than a recurring slot' do
      at = 3.days.from_now.change(usec: 0)
      schedule = one_time(run_at: at)
      expect(schedule.calculate_next_scheduled_at.change(usec: 0)).to eq(at)
    end

    it 'is not due before run_at' do
      one_time(run_at: 2.days.from_now)
      expect(SocialPostSchedule.due).to be_empty
    end
  end

  describe 'when it fires' do
    it 'publishes without waiting on an approval email' do
      schedule = one_time
      expect(SocialPostMailer).not_to receive(:approval_needed)
      expect(PublishSocialPostJob).to receive(:perform_later)

      described_class.new.send(:generate_for, schedule)

      expect(company.social_posts.last.status).to eq('approved')
    end

    it 'retires itself instead of recurring' do
      schedule = one_time
      described_class.new.send(:generate_for, schedule)
      schedule.reload

      expect(schedule.active).to be(false)
      expect(schedule.next_scheduled_at).to be_nil
      expect(schedule.last_generated_at).to be_present
    end

    it 'does not come back around on the next tick' do
      one_time
      described_class.new.perform
      expect { described_class.new.perform }
        .not_to change { company.social_posts.count }
    end

    it 'features the pinned unit rather than drawing from inventory' do
      other = company.vehicles.create!(
        inventory_id: "INV-#{SecureRandom.hex(4)}", listing_type: 'manufactured_home',
        serial_number: "SN-#{SecureRandom.hex(4)}", year: 2020, make: 'Other', model: 'Model',
        bedrooms: 2, bathrooms: 1, status: 'available'
      )
      expect(other).to be_persisted

      schedule = one_time(vehicle_id: vehicle.id)
      described_class.new.send(:generate_for, schedule)

      expect(company.social_posts.last.vehicle_id).to eq(vehicle.id)
    end

    it 'retires rather than looping forever when it needs a unit and finds none' do
      schedule = one_time(require_vehicle: true, intent_rotation: ['specific_unit'])
      described_class.new.send(:generate_for, schedule)

      expect(schedule.reload.active).to be(false)
    end
  end

  describe 'recurring schedules' do
    it 'still honors auto_approve rather than publishing unattended' do
      schedule = company.social_post_schedules.create!(
        frequency: 'weekly', auto_approve: false, require_vehicle: false
      )
      expect(schedule.effective_auto_approve?).to be(false)
    end

    it 'keeps recurring after it fires' do
      schedule = company.social_post_schedules.create!(
        frequency: 'weekly', auto_approve: true, require_vehicle: false,
        intent_rotation: ['education']
      )
      described_class.new.send(:generate_for, schedule)
      schedule.reload

      expect(schedule.active).to be(true)
      expect(schedule.next_scheduled_at).to be_present
    end
  end
end
