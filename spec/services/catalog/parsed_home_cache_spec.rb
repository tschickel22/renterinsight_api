# frozen_string_literal: true

require 'rails_helper'

# Re-crawling a source to backfill one new subscriber costs a full pass over the
# vendor's site — 716s for Kabco, 408s for Sunshine Homes, 375s for Clayton in
# production — for data already parsed. This is what avoids that.
RSpec.describe Catalog::ParsedHomeCache do
  let(:source) do
    create(:catalog_source, base_url: 'https://example.com', config: { 'crawl_delay' => 5 })
  end

  def home(key: 'model-a')
    Catalog::NormalizedHome.new(
      source_key: key, source_url: "https://example.com/homes/#{key}",
      model_name: 'The Colossal', model_id: 'ABC123', series: 'Heritage',
      property_type: ['Double Wide'], bedrooms: 3, bathrooms: 2.5,
      dimensions: '32x60', square_feet: 1600, description: nil,
      features: { 'Home details' => ['Double Wide'] },
      images: [{ 'source_url' => 'https://cdn.example.com/a.jpg', 'is_floorplan' => false }],
      virtual_tour_url: 'https://my.matterport.com/show/?m=abc',
      raw: { 'retail_price' => 108_900.0 }
    )
  end

  describe 'round trip' do
    it 'restores every field it was given' do
      described_class.write(source, [home])
      restored = described_class.read(source).first

      original = home
      Catalog::NormalizedHome::ATTRS.each do |attr|
        expect(restored.public_send(attr)).to eq(original.public_send(attr)), "#{attr} differed"
      end
    end

    # If the restored home hashed differently, every cached backfill would look
    # like a change and re-write vehicles that had not moved.
    it 'preserves the content hash, so change detection still sees no change' do
      described_class.write(source, [home])
      expect(described_class.read(source).first.content_hash).to eq(home.content_hash)
    end

    it 'survives the ingestion smoke test' do
      described_class.write(source, [home])
      expect(described_class.read(source).first).to be_valid_smoke
    end
  end

  describe 'freshness' do
    it 'returns nil when nothing is cached' do
      expect(described_class.read(source)).to be_nil
    end

    it 'returns nil once past an explicit max age' do
      described_class.write(source, [home])
      expect(described_class.read(source, max_age: 1.hour)).to be_present

      travel_to(3.hours.from_now) do
        expect(described_class.read(source, max_age: 1.hour)).to be_nil
      end
    end

    # Crawling to backfill a dealer more often than the source refreshes itself
    # contradicts the schedule — a weekly source would pay a full crawl on day 3
    # to produce data barely newer than the cache.
    describe 'default window follows the source schedule' do
      {
        'daily'  => [19.hours, 21.hours],
        'weekly' => [5.days, 7.days],
        'manual' => [20.days, 31.days]
      }.each do |schedule, (still_fresh, now_stale)|
        it "keeps a #{schedule} source's parse for its own cadence" do
          source.update!(schedule: schedule)
          described_class.write(source, [home])

          travel_to(still_fresh.from_now) { expect(described_class.read(source)).to be_present }
          travel_to(now_stale.from_now)   { expect(described_class.read(source)).to be_nil }
        end
      end

      it 'exposes the window it derived' do
        source.update!(schedule: 'weekly')
        expect(described_class.max_age_for(source)).to eq(6.days)
      end
    end

    it 'reports when it was cached' do
      described_class.write(source, [home])
      expect(described_class.cached_at(source)).to be_within(5.seconds).of(Time.current)
    end
  end

  # Serving homes parsed under old settings would be worse than re-crawling:
  # rebinding a Trove snapshot or repointing a URL changes what the source means.
  describe 'self-invalidation' do
    it 'ignores a cache written under a different base_url' do
      described_class.write(source, [home])
      source.update!(base_url: 'https://elsewhere.example.com')

      expect(described_class.read(source)).to be_nil
    end

    it 'ignores a cache written under different config' do
      described_class.write(source, [home])
      source.update!(config: source.config.merge('snapshot_key' => 'legacy_housing'))

      expect(described_class.read(source)).to be_nil
    end

    it 'is unaffected by config key order' do
      source.update!(config: { 'a' => 1, 'b' => 2 })
      described_class.write(source, [home])
      source.update!(config: { 'b' => 2, 'a' => 1 })

      expect(described_class.read(source)).to be_present
    end
  end

  describe 'guard rails' do
    it 'stores nothing for an empty parse, so a bad run cannot poison the cache' do
      described_class.write(source, [])
      expect(described_class.read(source)).to be_nil
    end

    it 'remembers that a parse was degraded' do
      described_class.write(source, [home], degraded: true)
      expect(described_class.degraded?(source)).to be(true)
    end

    it 'defaults to not degraded' do
      described_class.write(source, [home])
      expect(described_class.degraded?(source)).to be(false)
    end

    it 'clears on demand' do
      described_class.write(source, [home])
      described_class.clear(source)
      expect(described_class.read(source)).to be_nil
    end

    # A cache failure must never sink a run that already succeeded.
    it 'swallows a write failure' do
      allow(Setting).to receive(:set).and_raise(StandardError, 'db gone')
      expect { described_class.write(source, [home]) }.not_to raise_error
    end

    it 'keeps sources separate' do
      other = create(:catalog_source, base_url: 'https://other.example.com')
      described_class.write(source, [home(key: 'mine')])

      expect(described_class.read(other)).to be_nil
      expect(described_class.read(source).first.source_key).to eq('mine')
    end
  end
end
