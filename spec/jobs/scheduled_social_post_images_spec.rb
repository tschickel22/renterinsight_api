# frozen_string_literal: true

require 'rails_helper'

# Covers how a scheduled post gets its image: unit photos first, then the
# schedule's fallback pool (rotating), then the company logo only if opted in.
# Nothing is ever invented — an imageless post is a valid outcome.
RSpec.describe GenerateScheduledSocialPostsJob, 'image resolution' do
  let(:company) { Company.create!(name: "C-#{SecureRandom.hex(4)}", industry: 'manufactured_housing') }
  let(:job) { described_class.new }

  def schedule_with(**attrs)
    company.social_post_schedules.create!(frequency: 'weekly', **attrs)
  end

  def vehicle_with(photo: nil, images: [])
    company.vehicles.create!(
      inventory_id: "INV-#{SecureRandom.hex(4)}",
      listing_type: 'manufactured_home',
      serial_number: "SN-#{SecureRandom.hex(4)}",
      year: 2024, make: 'Clayton', model: 'Breeze',
      bedrooms: 3, bathrooms: 2, status: 'available',
      photo_url: photo, images: images
    )
  end

  def resolve(schedule, vehicle) = job.send(:resolve_images, schedule, vehicle)

  it 'prefers the featured unit photos over everything else' do
    schedule = schedule_with(image_pool: ['https://x/pool.jpg'], use_logo_fallback: true)
    vehicle  = vehicle_with(photo: 'https://x/unit.jpg')

    expect(resolve(schedule, vehicle)).to eq(['https://x/unit.jpg'])
  end

  it 'falls back to the pool when the unit has no photos' do
    schedule = schedule_with(image_pool: ['https://x/pool.jpg'])
    expect(resolve(schedule, vehicle_with)).to eq(['https://x/pool.jpg'])
  end

  it 'rotates through the pool instead of reusing the first image' do
    schedule = schedule_with(image_pool: %w[https://x/a.jpg https://x/b.jpg])
    picked = 4.times.map { resolve(schedule, nil).first }

    expect(picked).to eq(%w[https://x/a.jpg https://x/b.jpg https://x/a.jpg https://x/b.jpg])
  end

  context 'logo fallback' do
    before { Setting.set('Company', company.id, 'branding', { 'logo' => 'https://x/logo.png' }) }

    it 'uses the company logo when opted in and nothing else is available' do
      expect(resolve(schedule_with(use_logo_fallback: true), nil)).to eq(['https://x/logo.png'])
    end

    it 'leaves the post imageless when the option is off' do
      expect(resolve(schedule_with(use_logo_fallback: false), nil)).to eq([])
    end

    it 'ranks below the pool, so the logo is a last resort' do
      schedule = schedule_with(image_pool: ['https://x/pool.jpg'], use_logo_fallback: true)
      expect(resolve(schedule, nil)).to eq(['https://x/pool.jpg'])
    end
  end

  it 'returns nothing when the company has no logo set, even if opted in' do
    expect(resolve(schedule_with(use_logo_fallback: true), nil)).to eq([])
  end
end
