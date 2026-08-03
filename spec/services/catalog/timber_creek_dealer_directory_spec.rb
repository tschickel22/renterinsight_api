# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Catalog::TimberCreekDealerDirectory do
  # Mirrors the real page shape: a state page whose store-locator map is fed by a
  # `var markers = [...]` JSON array carrying the complete retailer record, and a
  # retailer landing page that links each state as /{state}-manufactured-homes/.
  def marker(id:, name:, city:, state: 'LA', slug: nil, status: 1)
    {
      'id' => id, 'name' => name,
      'street' => '4478 NE Evangeline Thwy', 'city' => city, 'state' => state,
      'zipcode' => '70520', 'phone' => '(337) 896-1110', 'phoneSecondary' => nil,
      'websiteUrl' => 'https://www.atchafalayahomes.com/',
      'lat' => 30.2674424, 'lng' => -92.0181678, 'status' => status,
      'url' => "/dealer/#{id}/#{slug || name.parameterize}/#{city.parameterize}",
      'search_result_icon' => "https://d132mt2yijm03y.cloudfront.net/dealer/#{id}/logo.png",
      'pin' => '/wp-content/uploads/2024/04/map-pin-yellow.png'
    }
  end

  def state_page(markers)
    <<~HTML
      <html><body>
        <div id="dealer-result-map"></div>
        <script type="text/javascript">
          function initialize_dealer_map() {
            var allowMultipleInfoWindows = false;
            var markers = #{markers.to_json};
            var other = [{"not":"a dealer"}];
          }
        </script>
      </body></html>
    HTML
  end

  let(:retailers_page) do
    <<~HTML
      <html><body>
        <a href="/louisiana-manufactured-homes/">Louisiana</a>
        <a href="/texas-manufactured-homes/">Texas</a>
        <a href="/louisiana-manufactured-homes/">Louisiana again</a>
        <a href="/authorized-retailers/">Find Retailers</a>
        <a href="/single-wide-homes/">Single Wide</a>
      </body></html>
    HTML
  end

  subject(:directory) { described_class.new }

  describe '#discover_states' do
    it 'reads the state slugs off the retailer landing page, deduped' do
      expect(directory.discover_states(retailers_page)).to eq %w[louisiana texas]
    end

    it 'falls back to the known footprint when the page is unreachable' do
      expect(directory.discover_states(nil)).to eq described_class::FALLBACK_STATES
    end

    it 'falls back when the page links no state pages' do
      expect(directory.discover_states('<html><body>nothing</body></html>'))
        .to eq described_class::FALLBACK_STATES
    end
  end

  describe '#markers' do
    it 'parses the locator array' do
      html = state_page([marker(id: 1982, name: 'Atchafalaya Homes', city: 'Carencro')])
      expect(directory.markers(html).first['id']).to eq 1982
    end

    it 'stops at the end of the assignment rather than swallowing later script' do
      html = state_page([marker(id: 1982, name: 'Atchafalaya Homes', city: 'Carencro')])
      expect(directory.markers(html).size).to eq 1
    end

    it 'returns [] for a page with no locator' do
      expect(directory.markers('<html><body>no map here</body></html>')).to eq []
    end

    it 'returns [] rather than raising on malformed JSON' do
      expect(directory.markers('<script>var markers = [{"id":;</script>')).to eq []
    end
  end

  describe '#entries_for_state' do
    before do
      allow(directory).to receive(:http_get)
        .with('https://www.timbercreekhousing.com/louisiana-manufactured-homes/')
        .and_return(state_page([
                                 marker(id: 1982, name: 'Atchafalaya Homes', city: 'Carencro'),
                                 marker(id: 9999, name: 'Closed Homes', city: 'Houma', status: 0)
                               ]))
    end

    let(:entry) { directory.entries_for_state('louisiana').first }

    it 'normalizes a retailer into a directory row' do
      expect(entry).to include(
        'dealer_id' => 1982, 'slug' => 'atchafalaya-homes', 'name' => 'Atchafalaya Homes',
        'city' => 'Carencro', 'state' => 'LA', 'postal_code' => '70520',
        'phone' => '(337) 896-1110', 'latitude' => 30.2674424, 'longitude' => -92.0181678
      )
    end

    it 'builds the adapter base_url with a trailing slash, to avoid a 301 per crawl' do
      expect(entry['url'])
        .to eq 'https://www.timbercreekhousing.com/dealer/1982/atchafalaya-homes/carencro/'
    end

    it 'drops delisted retailers, whose dealer page is an empty shell' do
      expect(directory.entries_for_state('louisiana').map { |e| e['dealer_id'] }).to eq [1982]
    end

    it 'returns [] when the state page is unreachable' do
      allow(directory).to receive(:http_get).and_return(nil)
      expect(directory.entries_for_state('louisiana')).to eq []
    end
  end

  describe '#crawl' do
    before do
      allow(directory).to receive(:sleep)
      allow(directory).to receive(:http_get).with(a_string_including('/authorized-retailers/'))
                                            .and_return(retailers_page)
      allow(directory).to receive(:http_get).with(a_string_including('louisiana'))
                                            .and_return(state_page([
                                                                     marker(id: 1975, name: 'Mobile Mansions', city: 'Lafayette', slug: 'mobile-mansions'),
                                                                     marker(id: 5440, name: 'Mobile Mansions', city: 'Thibodaux', slug: 'mobile-mansions')
                                                                   ]))
      allow(directory).to receive(:http_get).with(a_string_including('texas'))
                                            .and_return(state_page([
                                                                     marker(id: 1975, name: 'Mobile Mansions', city: 'Lafayette', slug: 'mobile-mansions'),
                                                                     marker(id: 3001, name: 'Lone Star Homes', city: 'Tyler', state: 'TX')
                                                                   ]))
    end

    # Five separate Marty Wright dealerships share one slug on the live site;
    # keying on slug would collapse them into a single picker entry.
    it 'keeps distinct dealerships that share a slug' do
      ids = directory.crawl.map { |e| e['dealer_id'] }
      expect(ids).to contain_exactly(1975, 5440, 3001)
    end

    it 'dedupes a retailer listed under two states' do
      expect(directory.crawl.count { |e| e['dealer_id'] == 1975 }).to eq 1
    end

    it 'returns [] rather than raising when the crawl blows up' do
      allow(directory).to receive(:discover_states).and_raise(StandardError, 'boom')
      expect(directory.crawl).to eq []
    end
  end

  describe 'caching' do
    let(:entries) do
      [{ 'dealer_id' => 1982, 'slug' => 'atchafalaya-homes', 'name' => 'Atchafalaya Homes',
         'city' => 'Carencro', 'state' => 'LA',
         'url' => 'https://www.timbercreekhousing.com/dealer/1982/atchafalaya-homes/carencro/' }]
    end

    def write_cache(rows, fetched_at: Time.current)
      Setting.set('Platform', PlatformSetting::PLATFORM_SCOPE_ID, described_class::SETTING_KEY,
                  { 'fetched_at' => fetched_at.utc.iso8601, 'entries' => rows })
    end

    it 'reads cached entries without crawling' do
      write_cache(entries)
      expect(described_class).not_to receive(:new)
      expect(described_class.all.size).to eq 1
      expect(described_class.loaded?).to be true
    end

    it 'is stale with no cache' do
      expect(described_class.stale?).to be true
    end

    it 'is fresh inside the TTL and stale past it' do
      write_cache(entries)
      expect(described_class.stale?).to be false
      write_cache(entries, fetched_at: (described_class::CACHE_TTL + 1.day).ago)
      expect(described_class.stale?).to be true
    end

    # A site outage must not empty the picker for everyone.
    it 'keeps the previous cache when a refresh crawls nothing' do
      write_cache(entries)
      allow_any_instance_of(described_class).to receive(:crawl).and_return([])
      expect(described_class.refresh!.size).to eq 1
      expect(described_class.all.size).to eq 1
    end

    it 'replaces the cache on a successful refresh' do
      write_cache(entries)
      fresh = entries + [{ 'dealer_id' => 3001, 'name' => 'Lone Star Homes', 'state' => 'TX' }]
      allow_any_instance_of(described_class).to receive(:crawl).and_return(fresh)
      expect(described_class.refresh!.size).to eq 2
      expect(described_class.fetched_at).to be_within(1.minute).of(Time.current)
    end
  end

  describe '.search' do
    before do
      Setting.set('Platform', PlatformSetting::PLATFORM_SCOPE_ID, described_class::SETTING_KEY,
                  { 'fetched_at' => Time.current.utc.iso8601,
                    'entries' => [
                      { 'dealer_id' => 1982, 'slug' => 'atchafalaya-homes', 'name' => 'Atchafalaya Homes',
                        'city' => 'Carencro', 'state' => 'LA' },
                      { 'dealer_id' => 3001, 'slug' => 'lone-star-homes', 'name' => 'Lone Star Homes',
                        'city' => 'Tyler', 'state' => 'TX' }
                    ] })
    end

    it 'matches on name' do
      expect(described_class.search('atchaf').map { |e| e['dealer_id'] }).to eq [1982]
    end

    it 'matches on city' do
      expect(described_class.search('tyler').map { |e| e['dealer_id'] }).to eq [3001]
    end

    it 'matches on dealer id, which is what the URL exposes' do
      expect(described_class.search('3001').map { |e| e['name'] }).to eq ['Lone Star Homes']
    end

    it 'filters by state' do
      expect(described_class.search('', state: 'LA').map { |e| e['dealer_id'] }).to eq [1982]
    end

    it 'returns everything, name-sorted, for a blank query' do
      expect(described_class.search('').map { |e| e['name'] })
        .to eq ['Atchafalaya Homes', 'Lone Star Homes']
    end

    it 'honours the limit' do
      expect(described_class.search('', limit: 1).size).to eq 1
    end
  end

  describe '.find_by_dealer_id' do
    before do
      Setting.set('Platform', PlatformSetting::PLATFORM_SCOPE_ID, described_class::SETTING_KEY,
                  { 'fetched_at' => Time.current.utc.iso8601,
                    'entries' => [{ 'dealer_id' => 1982, 'name' => 'Atchafalaya Homes' }] })
    end

    it 'finds by integer or string id' do
      expect(described_class.find_by_dealer_id(1982)['name']).to eq 'Atchafalaya Homes'
      expect(described_class.find_by_dealer_id('1982')['name']).to eq 'Atchafalaya Homes'
    end

    it 'returns nil for an unknown id' do
      expect(described_class.find_by_dealer_id(1)).to be_nil
    end
  end
end
