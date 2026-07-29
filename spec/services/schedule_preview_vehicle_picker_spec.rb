# frozen_string_literal: true

require 'rails_helper'

RSpec.describe SchedulePreviewVehiclePicker do
  let(:company) { Company.create!(name: "C-#{SecureRandom.hex(4)}", industry: 'manufactured_housing') }

  def build_vehicle(status:, photo: nil, images: [])
    company.vehicles.create!(
      inventory_id: "INV-#{SecureRandom.hex(4)}",
      listing_type: 'manufactured_home',
      serial_number: "SN-#{SecureRandom.hex(4)}",
      year: 2024, make: 'Clayton', model: 'Breeze',
      bedrooms: 3, bathrooms: 2,
      status: status, photo_url: photo, images: images
    )
  end

  describe 'inventory status selection' do
    it 'defaults to available only, preserving the original behavior' do
      build_vehicle(status: 'available_to_order', photo: 'https://x/a.jpg')
      expect(described_class.pick(company: company, intent: 'specific_unit')).to be_nil
    end

    it 'features a catalog home when available_to_order is permitted' do
      unit = build_vehicle(status: 'available_to_order', photo: 'https://x/a.jpg')
      picked = described_class.pick(
        company: company, intent: 'specific_unit',
        statuses: %w[available available_to_order]
      )
      expect(picked).to eq(unit)
    end

    it 'ignores unknown statuses rather than querying for them' do
      unit = build_vehicle(status: 'available', photo: 'https://x/a.jpg')
      picked = described_class.pick(company: company, intent: 'specific_unit', statuses: %w[bogus])
      expect(picked).to eq(unit)
    end

    it 'never features a sold home unless sold is explicitly permitted' do
      build_vehicle(status: 'sold', photo: 'https://x/a.jpg')
      expect(described_class.pick(company: company, intent: 'specific_unit')).to be_nil
    end
  end

  describe 'require_photos' do
    it 'skips a unit with no photo_url and no images' do
      build_vehicle(status: 'available')
      expect(
        described_class.pick(company: company, intent: 'specific_unit', require_photos: true)
      ).to be_nil
    end

    it 'accepts a unit carrying only an images array' do
      unit = build_vehicle(status: 'available', images: [{ 'url' => 'https://x/b.jpg' }])
      expect(
        described_class.pick(company: company, intent: 'specific_unit', require_photos: true)
      ).to eq(unit)
    end

    it 'still returns a photoless unit when require_photos is off' do
      unit = build_vehicle(status: 'available')
      expect(described_class.pick(company: company, intent: 'specific_unit')).to eq(unit)
    end
  end

  describe '.pick_for' do
    it 'reads the statuses and photo requirement off the schedule' do
      unit = build_vehicle(status: 'available_to_order', photo: 'https://x/a.jpg')
      build_vehicle(status: 'available_to_order') # photoless — must be skipped

      schedule = company.social_post_schedules.create!(
        frequency: 'weekly',
        inventory_statuses: %w[available_to_order],
        require_photos: true
      )

      expect(described_class.pick_for(schedule, intent: 'specific_unit')).to eq(unit)
    end
  end

  describe 'non-dealer industries' do
    it 'never attaches a unit for a saas tenant' do
      saas = Company.create!(name: "S-#{SecureRandom.hex(4)}", industry: 'saas')
      expect(described_class.pick(company: saas, intent: 'specific_unit')).to be_nil
    end
  end
end
