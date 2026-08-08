# frozen_string_literal: true

require 'rails_helper'

# Fixtures mirror the live adventurehomes.net markup: a WordPress/Jupiter X
# child theme whose floorplan page carries a labeled <li> spec list, a hero plan
# drawing, a swiper gallery, a series Standard Features PDF, an optional
# Matterport button — and, in the same container, a "Related Floor Plan" block
# repeating OTHER models' cards and photos.
RSpec.describe Catalog::Adapters::AdventureHomesAdapter do
  let(:source) do
    build(:catalog_source, adapter_type: 'adventure_homes', base_url: 'https://adventurehomes.net')
  end
  let(:adapter) { described_class.new(source) }

  let(:sitemap) do
    <<~XML
      <?xml version="1.0" encoding="UTF-8"?>
      <urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">
        <url><loc>https://adventurehomes.net/floorplan/0663ls/</loc></url>
        <url><loc>https://adventurehomes.net/floorplan/1401s-2/</loc></url>
      </urlset>
    XML
  end

  let(:standards_pdf) do
    pdf = Prawn::Document.new(page_size: 'LETTER', margin: 0)
    pdf.font 'Helvetica'
    pdf.draw_text 'Lakeside Series', at: [110, 722], size: 36
    pdf.draw_text 'Exterior', at: [78, 690], size: 14
    pdf.draw_text 'LP Smartside Siding', at: [72, 674], size: 10
    pdf.draw_text 'Kitchen', at: [326, 690], size: 14
    pdf.draw_text 'Black 18cf Refrigerator', at: [320, 674], size: 10
    pdf.render
  end

  # The neighbour whose card sits in the Related Floor Plan block. Nothing from
  # here may reach the parsed home.
  def related_block
    <<~HTML
      <div class="related_floorplan">
        <div class="item">
          <div class="right"><img src="https://adventurehomes.net/wp-content/uploads/2024/09/RELATED-neighbour.jpg"></div>
          <div class="left floor-CDetails">
            <h3><a href="https://adventurehomes.net/floorplan/6481ls-8-stretch/">6481LS (8' Stretch)</a></h3>
            <ul>
              <li><b>Beds:</b> 9</li>
              <li><b>Sq Ft:</b> 720</li>
              <li><b>Baths:</b> 9</li>
              <li><b>Series:</b> Neighbour Series</li>
              <li><b>WxL:</b> 16x56</li>
            </ul>
          </div>
        </div>
      </div>
    HTML
  end

  def detail_html(gallery: true, tour: 'https://discover.matterport.com/space/4fK17MgETcm')
    photos = if gallery
               (1..2).map do |n|
                 <<~SLIDE
                   <div class="swiper-slide"><div class="swiper-zoom-container">
                     <a href="https://adventurehomes.net/wp-content/uploads/2024/09/#{n}-Lakeside-0663LS-Exterior.jpg">
                       <img loading="lazy" src="https://adventurehomes.net/wp-content/uploads/2024/09/#{n}-Lakeside-0663LS-Exterior.jpg" />
                     </a>
                   </div></div>
                 SLIDE
               end.join
             else
               ''
             end

    tour_button = tour ? %(<a class="req_qut_btn" target="__blank" href="#{tour}">3D Tour</a>) : ''

    <<~HTML
      <html><head><meta property="og:title" content="0663LS - Adventure Homes" /></head>
      <body class="floorplan-template-default single-floorplan">
      <div class="singlefplan">
        <div class="col-md-6 left"><div class="img">
          <a href="https://adventurehomes.net/wp-content/uploads/2026/04/0663LS-scaled.jpg" class="floor-image-popup">
            <img loading="lazy" src="https://adventurehomes.net/wp-content/uploads/2026/04/0663LS-scaled.jpg" />
          </a>
        </div></div>
        <div class="col-md-6 right"><div class="floor_specification">
          <div class="specification_list">
            <h2 class="floor_name">
                    Lincoln
                        |
                    0663LS          </h2>
            <ul>
              <li><b>Model Number:</b> <span id="curr_model_name">0663LS</span></li>
              <li><b>Home Series:</b> Lakeside</li>
              <li><b>Bedrooms:</b> 3</li>
              <li><b>Square Feet:</b> 1560 </li>
              <li><b>Bathrooms:</b> 2</li>
              <li><b>WxL:</b> 32x66</li>
            </ul>
          </div>
          <div class="floor_buttons">
            <a class="literature_btn" href="https://adventurehomes.net/wp-content/uploads/2026/01/Lakeside-Standards-January-19th-2026.pdf">Standard Features</a>
            #{tour_button}
          </div>
        </div></div>
        <div class="gallery_section">
          <div class="floor_gallery_image"><div id="floor-slider" class="swiper">
            <div class="swiper-wrapper">#{photos}</div>
          </div></div>
        </div>
        #{related_block}
      </div>
      </body></html>
    HTML
  end

  let(:floorplan_rest) do
    [{ 'slug' => '0663ls', 'link' => 'https://adventurehomes.net/floorplan/0663ls/', 'home_type' => [37] },
     { 'slug' => '1401s-2', 'link' => 'https://adventurehomes.net/floorplan/1401s-2/', 'home_type' => [38] }].to_json
  end
  let(:home_type_rest) do
    [{ 'id' => 37, 'name' => 'HUD - Manufactured Homes' },
     { 'id' => 38, 'name' => 'MOD - Modular Homes' }].to_json
  end

  # Route every fetch the adapter makes; nil for anything unexpected so a stray
  # request shows up as a missing value rather than a silent pass.
  def stub_http(html: detail_html, sitemap_body: sitemap, pdf: standards_pdf)
    allow(adapter).to receive(:http_get) do |url, **|
      case url
      when %r{floorplan-sitemap\.xml}   then sitemap_body
      when %r{/wp-json/wp/v2/home_type} then home_type_rest
      when %r{/wp-json/wp/v2/floorplan} then floorplan_rest
      when /\.pdf\z/                    then pdf
      when %r{/floorplan/}              then html
      end
    end
  end

  describe '#discover' do
    it 'returns a slug per floorplan in the sitemap' do
      stub_http
      expect(adapter.discover).to eq(%w[0663ls 1401s-2])
    end

    it 'honours a limit' do
      stub_http
      expect(adapter.discover(limit: 1)).to eq(['0663ls'])
    end

    it 'falls back to the WordPress REST API when the sitemap is unavailable' do
      stub_http(sitemap_body: nil)
      expect(adapter.discover).to eq(%w[0663ls 1401s-2])
    end

    it 'returns no keys when neither source answers' do
      allow(adapter).to receive(:http_get).and_return(nil)
      expect(adapter.discover).to eq([])
    end
  end

  describe '#parse' do
    subject(:home) { adapter.parse(adapter.fetch('0663ls')) }

    before { stub_http }

    it 'reads the labeled spec list' do
      expect(home).to have_attributes(
        source_key:  '0663ls',
        model_id:    '0663LS',
        series:      'Lakeside',
        bedrooms:    3,
        bathrooms:   '2',
        square_feet: 1560,
        dimensions:  '32x66'
      )
    end

    it 'collapses the theme\'s whitespace in the model name' do
      expect(home.model_name).to eq('Lincoln | 0663LS')
    end

    it 'leaves description blank, because the site publishes none' do
      expect(home.description).to be_nil
    end

    it 'reads property type from the home_type taxonomy' do
      expect(home.property_type).to eq(['HUD - Manufactured Homes'])
    end

    it 'passes the smoke test' do
      expect(home).to be_valid_smoke
    end

    describe 'the Related Floor Plan block' do
      it 'does not take the neighbour\'s specs' do
        expect(home.bedrooms).to eq(3)
        expect(home.bathrooms).to eq('2')
        expect(home.series).to eq('Lakeside')
      end

      it 'does not take the neighbour\'s photos' do
        expect(home.image_source_urls).not_to include(a_string_including('RELATED-neighbour'))
      end
    end

    describe 'images' do
      it 'tags the hero drawing as the floorplan' do
        expect(home.floorplan_images.map { |i| i['source_url'] })
          .to eq(['https://adventurehomes.net/wp-content/uploads/2026/04/0663LS-scaled.jpg'])
      end

      it 'adds the gallery photos' do
        expect(home.image_source_urls.size).to eq(3)
      end

      # Half the catalog has no gallery, so the hero is what keeps these homes
      # passing the smoke test.
      context 'when the gallery is empty' do
        before { stub_http(html: detail_html(gallery: false)) }

        it 'still yields the hero drawing' do
          expect(home.image_source_urls.size).to eq(1)
          expect(home).to be_valid_smoke
        end
      end
    end

    describe 'the 3D tour' do
      it 'takes the discover.matterport.com/space form' do
        expect(home.virtual_tour_url).to eq('https://discover.matterport.com/space/4fK17MgETcm')
      end

      context 'with the matterport.com/discover/space form' do
        before { stub_http(html: detail_html(tour: 'https://matterport.com/discover/space/CJLeuYqkUGd')) }

        it 'takes it too' do
          expect(home.virtual_tour_url).to eq('https://matterport.com/discover/space/CJLeuYqkUGd')
        end
      end

      context 'when the plan has no tour' do
        before { stub_http(html: detail_html(tour: nil)) }

        it 'leaves it blank' do
          expect(home.virtual_tour_url).to be_nil
        end
      end
    end

    describe 'standard features' do
      it 'parses them out of the series PDF' do
        expect(home.features).to eq(
          'Exterior' => ['LP Smartside Siding'],
          'Kitchen'  => ['Black 18cf Refrigerator']
        )
      end

      it 'records the sheet it used and when it took effect' do
        expect(home.raw['standards_pdf_url']).to end_with('Lakeside-Standards-January-19th-2026.pdf')
        expect(home.raw['standards_effective']).to eq('2026-01-19')
      end

      it 'fetches each series sheet once, however many homes cite it' do
        adapter.parse(adapter.fetch('0663ls'))
        adapter.parse(adapter.fetch('0663ls'))
        expect(adapter).to have_received(:http_get).with(/\.pdf\z/, any_args).once
      end

      it 'survives an unreadable sheet without losing the home' do
        stub_http(pdf: 'not a pdf')
        expect(home.features).to eq({})
        expect(home.model_name).to eq('Lincoln | 0663LS')
      end
    end

    it 'records no price, because Adventure quotes through its retailers' do
      expect(home.price_quote_url).to be_nil
    end

    it 'returns a home even when the page fails to fetch' do
      allow(adapter).to receive(:http_get).and_return(nil)
      expect(adapter.parse(adapter.fetch('0663ls')).source_key).to eq('0663ls')
    end
  end

  describe '#crawl_delay' do
    it 'defaults to 5s, since back-to-back fetches stall the site' do
      expect(adapter.crawl_delay).to eq(5)
    end

    it 'is overridable per source' do
      source.config = { 'crawl_delay' => 12 }
      expect(adapter.crawl_delay).to eq(12)
    end
  end

  describe '#diagnostics' do
    it 'explains a zero-discovery run' do
      allow(adapter).to receive(:http_probe).and_return(
        { url: 'x', status: 403, bytes: 12, body: 'Just a moment... cloudflare' }
      )
      expect(adapter.diagnostics).to include(adapter: 'adventure_homes', sitemap_status: 403,
                                             looks_blocked: true, floorplan_count: 0)
    end
  end

  # SiteGround's Anti-Bot AI challenges our Render egress, so a run from the
  # platform never sees the site. A snapshot captured somewhere that can reach
  # them runs the same ingestion path from stored homes.
  describe 'running from a snapshot' do
    let(:live_home) do
      stub_http
      adapter.parse(adapter.fetch('0663ls'))
    end

    let(:snapshot_source) do
      build(:catalog_source, adapter_type: 'adventure_homes',
                             base_url: 'https://adventurehomes.net',
                             config: { 'snapshot_key' => 'adventure_homes' })
    end
    let(:snapshot_adapter) { described_class.new(snapshot_source) }

    before do
      Catalog::HomesSnapshot.write(
        'adventure_homes',
        Catalog::HomesSnapshot.build(source: snapshot_source, homes: [live_home])
      )
    end

    it 'discovers the captured homes' do
      expect(snapshot_adapter.discover).to eq(['0663ls'])
    end

    it 'makes no HTTP request at all' do
      expect(snapshot_adapter).not_to receive(:http_get)
      snapshot_adapter.parse(snapshot_adapter.fetch('0663ls'))
    end

    it 'waits for nothing, since there is no site to be polite to' do
      expect(snapshot_adapter.crawl_delay).to eq(0)
    end

    it 'rebuilds a home identical to the crawled one' do
      restored = snapshot_adapter.parse(snapshot_adapter.fetch('0663ls'))

      expect(restored.model_name).to eq(live_home.model_name)
      expect(restored.features).to eq(live_home.features)
      expect(restored.virtual_tour_url).to eq(live_home.virtual_tour_url)
      # Equal hashes are what make a re-capture update only genuine changes.
      expect(restored.content_hash).to eq(live_home.content_hash)
    end

    it 'says it is running from a snapshot, so it is never mistaken for live' do
      expect(snapshot_adapter.snapshot_info)
        .to include('key' => 'adventure_homes', 'home_count' => 1)
      expect(snapshot_adapter.diagnostics)
        .to include(mode: 'snapshot', snapshot_found: true, home_count: 1)
    end

    # Fails closed: a bound key with nothing stored must not fall back to a live
    # crawl, which on Render walks into the captcha and reports an empty catalog
    # while the operator believes they are running from a capture.
    it 'refuses to crawl when the bound snapshot is missing' do
      snapshot_source.config = { 'snapshot_key' => 'never_uploaded' }

      expect(snapshot_adapter).not_to receive(:http_get)
      expect(snapshot_adapter.discover).to eq([])
      expect(snapshot_adapter.fetch('0663ls')).to be_nil
      expect(snapshot_adapter.diagnostics)
        .to include(mode: 'snapshot', snapshot_found: false)
    end

    it 'goes back to crawling when the key is cleared' do
      snapshot_source.config = {}
      stub_http
      allow(snapshot_adapter).to receive(:http_get) { |url, **| url.match?(/sitemap/) ? sitemap : detail_html }

      expect(snapshot_adapter.discover).to eq(%w[0663ls 1401s-2])
      expect(snapshot_adapter.crawl_delay).to eq(5)
    end
  end

  describe 'registration' do
    it 'is reachable through the adapter registry' do
      expect(Catalog::AdapterRegistry.for(source)).to be_a(described_class)
    end

    it 'is an allowed adapter type' do
      expect(CatalogSource::ADAPTER_TYPES).to include('adventure_homes')
    end
  end
end
