# frozen_string_literal: true

require 'rails_helper'

# Fixtures mirror liveoakmanufacturedhomes.com: a WordPress `project` REST entry
# holding the name, category terms and featured photo, and a Divi page holding
# the gallery and tour, with a shared hero image as a CSS background.
RSpec.describe Catalog::Adapters::LiveOakAdapter do
  let(:root) { 'https://liveoakmanufacturedhomes.com' }
  let(:source) do
    build(:catalog_source, adapter_type: 'live_oak', base_url: "#{root}/",
                           config: { 'untracked_fields' => %w[model_id bathrooms dimensions square_feet description] })
  end
  let(:adapter) { described_class.new(source) }

  def term(name)
    { 'taxonomy' => 'project_category', 'name' => name }
  end

  def entry(slug: 'runner-singlewide', title: 'Bolt', terms: ['3 Bedroom', 'Runner Series', 'Singlewide', 'Porch Model'])
    {
      'slug' => slug,
      'link' => "#{root}/project/#{slug}/",
      'title' => { 'rendered' => title },
      '_embedded' => {
        'wp:featuredmedia' => [{ 'source_url' => "#{root}/wp-content/uploads/2020/06/featured.jpg", 'alt_text' => 'Front' }],
        'wp:term' => [terms.map { |t| term(t) }, [{ 'taxonomy' => 'project_tag', 'name' => 'Not a category' }]]
      }
    }
  end

  let(:page) do
    <<~HTML
      <html><head><style>.hero{background:url(#{root}/wp-content/uploads/2020/06/Saddlebrook-Exterior.jpg)}</style></head>
      <body><img id="logo" src="#{root}/wp-content/uploads/2022/11/LOH-Logo-Long.jpg">
      <div class="et_pb_gallery_items">
        <div class="et_pb_gallery_item"><div class="et_pb_gallery_image">
          <a href="#{root}/wp-content/uploads/2020/06/kitchen.jpg" title="kitchen"><img src="#{root}/wp-content/uploads/2020/06/kitchen-400x284.jpg"></a>
        </div><h3 class="et_pb_gallery_title">Bolt Kitchen</h3></div>
        <div class="et_pb_gallery_item"><div class="et_pb_gallery_image">
          <a href="#{root}/wp-content/uploads/2020/06/featured.jpg"><img src="#{root}/wp-content/uploads/2020/06/featured-400x284.jpg"></a>
        </div></div>
      </div>
      <iframe src="https://my.matterport.com/show/?m=pUGfANK3GEc"></iframe>
      </body></html>
    HTML
  end

  def stub_http(entries: [entry], html: page)
    allow(adapter).to receive(:http_get) do |url, **|
      url.include?('/wp-json/') ? entries.to_json : html
    end
  end

  describe '#discover' do
    it 'returns the slug of every project' do
      stub_http(entries: [entry, entry(slug: 'ace', title: 'Ace')])
      expect(adapter.discover).to eq(%w[runner-singlewide ace])
      expect(adapter.discover(limit: 1)).to eq(%w[runner-singlewide])
    end

    it 'reads past the first REST page' do
      full = Array.new(100) { |i| entry(slug: "home-#{i}") }
      allow(adapter).to receive(:http_get) do |url, **|
        (url.include?('page=1&') ? full : [entry(slug: 'last')]).to_json
      end
      expect(adapter.discover.size).to eq(101)
    end

    # A short list would read as removed homes and inactivate them on dealers.
    it 'finds nothing, rather than a partial catalog, when a later page fails' do
      full = Array.new(100) { |i| entry(slug: "home-#{i}") }
      allow(adapter).to receive(:http_get) { |url, **| url.include?('page=1&') ? full.to_json : nil }
      expect(adapter.discover).to eq([])
    end
  end

  describe '#parse' do
    subject(:home) do
      stub_http
      adapter.parse(adapter.fetch('runner-singlewide'))
    end

    it 'names the home from the title, not the slug' do
      expect(home.source_key).to eq('runner-singlewide')
      expect(home.model_name).to eq('Bolt')
      expect(home.source_url).to eq("#{root}/project/runner-singlewide/")
    end

    it 'sorts the category terms into bedrooms, width and series' do
      expect(home.bedrooms).to eq(3)
      expect(home.property_type).to eq(['Singlewide'])
      expect(home.series).to eq('Runner Series')
      expect(home.raw['porch_model']).to be(true)
    end

    it 'does not mistake a merchandising term for the series' do
      stub_http(entries: [entry(terms: ['Featured', 'Porch Model', '4 Bedroom', 'Plantation Series'])])
      expect(adapter.parse(adapter.fetch('runner-singlewide')).series).to eq('Plantation Series')
    end

    it 'leads with the featured photo, at full size, without the logo or shared hero' do
      urls = home.image_source_urls
      expect(urls).to eq(["#{root}/wp-content/uploads/2020/06/featured.jpg", "#{root}/wp-content/uploads/2020/06/kitchen.jpg"])
      expect(home.images.last['alt']).to eq('Bolt Kitchen')
    end

    it 'captures the Matterport tour' do
      expect(home.virtual_tour_url).to eq('https://my.matterport.com/show/?m=pUGfANK3GEc')
    end

    it 'leaves unpublished specs blank rather than inferring them' do
      expect(home.bathrooms).to be_nil
      expect(home.square_feet).to be_nil
      expect(home.dimensions).to be_nil
      expect(home.model_id).to be_nil
      expect(home.description).to be_nil
    end

    it 'keeps a home with its featured photo when its page fails to fetch' do
      stub_http(html: nil)
      home = adapter.parse(adapter.fetch('runner-singlewide'))
      expect(home.image_source_urls).to eq(["#{root}/wp-content/uploads/2020/06/featured.jpg"])
    end
  end

  describe 'the smoke check' do
    let(:home) do
      stub_http
      adapter.parse(adapter.fetch('runner-singlewide'))
    end

    it 'passes when the only blanks are fields the source marks untracked' do
      expect(home.valid_smoke?(untracked: source.untracked_fields)).to be(true)
    end

    it 'still fails those blanks for a source that does track them' do
      expect(home.valid_smoke?).to be(false)
    end

    it 'still fails a home with no bedrooms' do
      home.bedrooms = nil
      expect(home.valid_smoke?(untracked: source.untracked_fields)).to be(false)
    end
  end

  describe '#diagnostics' do
    it 'explains a zero-discovery run' do
      allow(adapter).to receive(:http_probe).and_return({ status: 403, bytes: 12, body: 'Just a moment... cloudflare' })
      expect(adapter.diagnostics).to include(adapter: 'live_oak', status: 403, looks_blocked: true)
    end
  end
end
