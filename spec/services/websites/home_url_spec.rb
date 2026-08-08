# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Websites::HomeUrl do
  let(:company) { Company.create!(name: "Co-#{SecureRandom.hex(3)}") }
  let(:vehicle) do
    company.vehicles.create!(vin: SecureRandom.hex(8), year: 2026, make: 'Champion', model: 'Shoal Creek',
                             status: 'available', sale_price: 236_900)
  end

  describe '.slug_for' do
    it 'reads like the home a buyer searched for' do
      expect(described_class.slug_for(vehicle)).to eq("2026-champion-shoal-creek-#{vehicle.id}")
    end

    # Year, make and model are all required, so this cannot happen through the
    # app today. It is covered because the fallback is what stops a URL builder
    # from returning "/homes/-12" if those validations are ever relaxed.
    it 'still produces an address when the home has no descriptive words' do
      bare = instance_double(Vehicle, id: 12, year: nil, make: nil, model: nil)

      expect(described_class.slug_for(bare)).to eq('12')
    end

    it 'strips punctuation a URL cannot carry' do
      odd = company.vehicles.create!(vin: SecureRandom.hex(8), year: 2026, make: "O'Brien & Sons", model: 'The 28/52',
                                     status: 'available')

      expect(described_class.slug_for(odd)).to match(/\A[a-z0-9-]+\z/)
    end

    it 'keeps the id visible on a very long name' do
      long = company.vehicles.create!(vin: SecureRandom.hex(8), year: 2026, make: 'A' * 40, model: 'B' * 40,
                                      status: 'available')
      slug = described_class.slug_for(long)

      expect(slug).to end_with("-#{long.id}")
      expect(slug.length).to be <= described_class::MAX_WORDS_LENGTH + long.id.to_s.length + 1
    end
  end

  describe '.vehicle_id_from' do
    it 'reads the id back out of a full slug' do
      expect(described_class.vehicle_id_from("/homes/2026-champion-shoal-creek-#{vehicle.id}"))
        .to eq(vehicle.id)
    end

    # The reason the id is the authority rather than the words: a home can be
    # renamed after someone has shared the link.
    it 'resolves a link whose words have since gone stale' do
      expect(described_class.vehicle_id_from("/homes/totally-different-words-#{vehicle.id}"))
        .to eq(vehicle.id)
    end

    it 'accepts a bare id, which is what the app itself links to' do
      expect(described_class.vehicle_id_from("/homes/#{vehicle.id}")).to eq(vehicle.id)
    end

    it 'tolerates a trailing slash' do
      expect(described_class.vehicle_id_from("/homes/shoal-creek-#{vehicle.id}/")).to eq(vehicle.id)
    end

    # Guessing here would let /homes/about-us load whatever vehicle it fancied.
    it 'refuses a slug with no id on the end' do
      expect(described_class.vehicle_id_from('/homes/about-us')).to be_nil
      expect(described_class.vehicle_id_from('/homes/')).to be_nil
    end

    it 'ignores paths that are not home addresses' do
      expect(described_class.vehicle_id_from('/inventory')).to be_nil
      expect(described_class.vehicle_id_from('/homesteading-guide-12')).to be_nil
    end
  end

  describe '.url_for' do
    it 'builds the absolute address used in the sitemap' do
      expect(described_class.url_for(vehicle, 'dealer.mydealertide.com'))
        .to eq("https://dealer.mydealertide.com/homes/2026-champion-shoal-creek-#{vehicle.id}")
    end

    it 'has no address without a host' do
      expect(described_class.url_for(vehicle, nil)).to be_nil
    end
  end

  describe '.matches?' do
    it 'recognises its own paths and nothing else' do
      expect(described_class.matches?('/homes/anything')).to be(true)
      expect(described_class.matches?('/homes')).to be(false)
      expect(described_class.matches?('/inventory/12')).to be(false)
    end
  end
end
