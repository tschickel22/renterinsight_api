# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Scrapers::ChampionImsSyncService, 'photos a dealer changed' do
  let(:company) { Company.create!(name: "Co-#{SecureRandom.hex(3)}") }
  let(:service) { described_class.allocate }
  let(:feed) { { images: [{ 'url' => 'https://champion/1.jpg' }], photo_url: 'https://champion/1.jpg', video_url: 'https://champion/v', model: 'Feed Model' } }
  let(:vehicle) { company.vehicles.build(source: 'champion_ims') }

  before do
    allow(service).to receive(:build_full_attrs).and_return(feed)
    allow(service).to receive(:resolve_location_id).and_return(nil)
  end

  it 'writes everything when the dealer changed nothing' do
    service.send(:apply_attrs!, vehicle, {}, nil, is_new: true)
    expect(vehicle).to have_attributes(photo_url: 'https://champion/1.jpg', video_url: 'https://champion/v', model: 'Feed Model')
  end

  it 'leaves alone only what the dealer changed' do
    mine = [{ 'url' => 'https://lot.example/mine.jpg' }]
    vehicle.assign_attributes(images: mine, photo_url: mine.first['url'])
    vehicle.catalog_last_synced_values = { Vehicle::DEALER_MEDIA_KEY => %w[images photo_url] }

    service.send(:apply_attrs!, vehicle, {}, nil, is_new: false)

    expect(vehicle.images).to eq(mine)
    expect(vehicle.photo_url).to eq(mine.first['url'])
    expect(vehicle.video_url).to eq('https://champion/v')
    expect(vehicle.model).to eq('Feed Model')
  end
end
