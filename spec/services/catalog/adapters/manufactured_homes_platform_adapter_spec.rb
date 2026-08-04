# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Catalog::Adapters::ManufacturedHomesPlatformAdapter do
  # Fixtures mirror the two permalink variants of the SAME platform: Sunshine
  # mounts floor plan pages at /floor-plan-detail/ inside .fp-card-container
  # cards, Timber Creek at /floorplan/ inside .floorplan-default cards and
  # defers the card thumbnail to a lazyload data-bg. Everything below the
  # markup — the spec icon row, the specification_tabs widget, the CloudFront
  # media host — is identical, which is why one adapter serves both.
  let(:cdn) { 'https://d132mt2yijm03y.cloudfront.net' }

  def source_for(base_url, config = {})
    instance_double(CatalogSource, base_url: base_url, config: config, manufacturer_id: nil)
  end

  # --- Timber Creek: dealer-scoped, /floorplan/ ---------------------------

  let(:tc_base) { 'https://www.timbercreekhousing.com/dealer/1982/atchafalaya-homes/carencro/' }

  let(:tc_grid_html) do
    <<~HTML
      <html><body>
        <h2>Showing 1-2 of 31 homes for sale from Atchafalaya Homes</h2>
        <div class="floorplan-default">
          <div class="fp-card-image lazyload" data-bg="#{cdn}/manufacturer/3391/floorplan/231596/Cahaba-1_card_lg.jpg"></div>
          <div class="details">
            <h4 class="home-name"><a href="/floorplan/231596-1982/atchafalaya-homes/carencro/creekside-series/the-cahaba-cs-1604/">Creekside Series / The Cahaba CS-1604</a></h4>
            <div class="fp-card-offered-by">Offered by: <a href="/dealer/1982/atchafalaya-homes/carencro/">Atchafalaya Homes</a></div>
            <div class="row fp-card-specs">
              <div><i class="icon-mfh-bed"></i> 3</div>
              <div><i class="icon-mfh-bath"></i> 2.00</div>
              <div><i class="icon-mfh-tapemeasure"></i> 1140 ft&sup2;</div>
              <div><i class="icon-mfh-lengthwidth"></i> 76'0" x 15'2"</div>
            </div>
          </div>
        </div>
        <div class="floorplan-default">
          <div class="fp-card-image lazyload" data-bg="#{cdn}/manufacturer/3391/floorplan/237110/Hangout-1_card_lg.jpg"></div>
          <div class="details">
            <h4 class="home-name"><a href="/floorplan/237110-1982/atchafalaya-homes/carencro/creekside-series/the-hangout-cs-3263/">Creekside Series / The Hangout CS-3263</a></h4>
          </div>
        </div>
        <!-- another retailer's home, cross-linked from the same page -->
        <div class="floorplan-default">
          <h4 class="home-name"><a href="/floorplan/999999-4055/some-other-dealer/houma/creekside-series/the-other-cs-1111/">Creekside Series / The Other CS-1111</a></h4>
        </div>
      </body></html>
    HTML
  end

  let(:tc_detail_html) do
    <<~HTML
      <html><head>
        <meta property="og:description" content="| bedrooms bathrooms square feet Brochure Price Quote Floor Plan Description Specifications Spec 1 Spec 2 Key 1: value 1Key 2: value 2 3D Tour Gallery [...]Read More... from Floorplan" />
      </head><body>
        <h1 class="elementor-heading-title">Creekside Series | The Cahaba CS-1604</h1>
        <div class="elementor-widget"><h2>Description</h2></div>
        <div class="elementor-widget elementor-widget-text-editor">
          The Creekside Series / The Cahaba CS-1604 built by Timber Creek Housing offers a cozy and functional living space.
        </div>
        <div class="container">
          <ul class="nav nav-tabs">
            <li class="nav-item"><a class="nav-link active" href="#tab_construction">Construction</a></li>
            <li class="nav-item"><a class="nav-link" href="#tab_kitchen">Kitchen</a></li>
          </ul>
          <div class="tab-content">
            <div class="tab-pane" id="tab_construction"><span>Insulation (Walls):</span> R-11<br><span>Side Wall Height:</span> 8'-6"<br></div>
            <div class="tab-pane" id="tab_kitchen"><span>Sink:</span> Stainless<br></div>
          </div>
        </div>
        <a href="https://my.matterport.com/show/?m=ZzFt31RGVjL">3D Tour</a>
        <img src="#{cdn}/manufacturer/3391/floorplan/231596/Cahaba-1.jpg" alt="Exterior" />
        <img src="#{cdn}/manufacturer/3391/floorplan/231596/Cahaba-1_thumb_xxl.jpg" alt="Exterior" />
        <img src="#{cdn}/manufacturer/3391/floorplan/231596/Cahaba%20CS-1604%20floor-plans-SMALL.jpg" alt="Floor Plan" />
        <div class="similar-homes">
          <img src="#{cdn}/manufacturer/2939/floorplan/223727/the-grove.jpg" alt="The Grove" />
        </div>
      </body></html>
    HTML
  end

  subject(:tc_adapter) { described_class.new(source_for(tc_base)) }

  def tc_discover
    tc_adapter.instance_variable_set(:@cards, {})
    tc_adapter.instance_variable_set(:@detail_urls, {})
    tc_adapter.send(:harvest_grid_cards, Nokogiri::HTML(tc_grid_html))
  end

  describe 'dealer scoping' do
    it 'infers the dealer id from a /dealer/{id}/ base_url' do
      expect(tc_adapter.dealer_scoped?).to be true
      expect(tc_adapter.dealer_id).to eq '1982'
    end

    it 'discovers only homes whose detail URL carries this dealer id' do
      expect(tc_discover).to contain_exactly('231596', '237110')
    end

    it 'skips sitemap discovery entirely, since a sitemap is site-wide' do
      expect(tc_adapter).not_to receive(:discover_via_sitemap)
      allow(tc_adapter).to receive(:discover_via_grid).and_return(%w[231596])
      expect(tc_adapter.discover).to eq %w[231596]
    end

    it 'treats a manufacturer-wide base_url as unscoped' do
      adapter = described_class.new(source_for('https://www.sunshinehomes-inc.com/manufactured-home-floor-plans/'))
      expect(adapter.dealer_scoped?).to be false
    end

    it 'accepts an explicit dealer_id override for a non-/dealer/ base_url' do
      adapter = described_class.new(source_for('https://example.com/homes/', { 'dealer_id' => '77' }))
      expect(adapter.dealer_id).to eq '77'
    end
  end

  describe 'grid cards' do
    it 'reads the lazyload data-bg thumbnail' do
      tc_discover
      card = tc_adapter.instance_variable_get(:@cards)['231596']
      expect(card['image']).to include('/floorplan/231596/Cahaba-1_card_lg.jpg')
    end

    it 'reads the icon-row specs and the multi-word series off the card title' do
      tc_discover
      card = tc_adapter.instance_variable_get(:@cards)['231596']
      expect(card).to include('beds' => '3', 'baths' => '2.00', 'sqft' => '1140',
                              'series' => 'Creekside Series')
      expect(card['dimensions']).to eq %(76'0" x 15'2")
    end

    it 'reads an inline background-image thumbnail too' do
      html = <<~HTML
        <div class="fp-card-container">
          <div class="fp-card-image" style="background-image: url(#{cdn}/manufacturer/2459/floorplan/224988/a.jpg);"></div>
          <a href="/floor-plan-detail/224988-2508/x/">Prime / The Eastwood PRI3268-2004</a>
        </div>
      HTML
      adapter = described_class.new(source_for('https://www.sunshinehomes-inc.com/manufactured-home-floor-plans/'))
      adapter.instance_variable_set(:@cards, {})
      adapter.instance_variable_set(:@detail_urls, {})
      adapter.send(:harvest_grid_cards, Nokogiri::HTML(html))
      expect(adapter.instance_variable_get(:@cards)['224988']['image']).to include('/224988/a.jpg')
    end
  end

  describe 'parsing a /floorplan/ detail page' do
    let(:home) do
      tc_discover
      tc_adapter.parse(
        key:  '231596',
        url:  "#{tc_base}../../floorplan/231596-1982/",
        html: tc_detail_html,
        card: tc_adapter.instance_variable_get(:@cards)['231596']
      )
    end

    it 'splits a pipe-separated heading into series, name and model id' do
      expect(home.series).to eq 'Creekside Series'
      expect(home.model_name).to eq 'The Cahaba'
      expect(home.model_id).to eq 'CS-1604'
    end

    it 'still splits the slash-separated Sunshine heading shape' do
      expect(tc_adapter.send(:name_from_heading, 'Prime / The Show Stopper PRI3284-2058'))
        .to eq 'The Show Stopper'
      expect(tc_adapter.send(:series_from_heading, 'Prime / The Show Stopper PRI3284-2058'))
        .to eq 'Prime'
    end

    it 'prefers the on-page Description section over the unrendered og:description' do
      expect(home.description).to start_with('The Creekside Series / The Cahaba CS-1604 built by')
      expect(home.description).not_to include('Key 1: value 1')
    end

    it 'never falls back to the Elementor placeholder og:description' do
      doc = Nokogiri::HTML(tc_detail_html.sub(%r{<div class="elementor-widget"><h2>Description</h2></div>}, ''))
      expect(tc_adapter.send(:meta_description, doc)).to be_nil
    end

    it 'reads the specification tabs' do
      expect(home.features.keys).to eq %w[Construction Kitchen]
      expect(home.features['Construction']).to include('Insulation (Walls): R-11')
    end

    it 'keeps the grid-card specs' do
      expect(home.bedrooms).to eq 3
      expect(home.square_feet).to eq 1140
      expect(home.dimensions).to eq %(76'0" x 15'2")
    end

    it 'captures the Matterport tour' do
      expect(home.virtual_tour_url).to include('ZzFt31RGVjL')
    end

    # The platform tags each home with a "Manufactured"/"Modular" pill. Scanning
    # the whole page text instead matched the site's own nav links
    # ("Manufactured Homes", "Modular Homes") on every page, so every home came
    # back as BOTH types.
    describe 'property type' do
      let(:nav) do
        <<~HTML
          <nav class="elementor-nav-menu">
            <a href="/manufactured-homes/">Manufactured Homes</a>
            <a href="/modular-homes/">Modular Homes</a>
          </nav>
        HTML
      end

      def type_for(body)
        tc_adapter.parse(key: '231596', url: 'https://x/',
                         html: "<html><body>#{nav}#{body}</body></html>", card: {}).property_type
      end

      it 'reads the tag pill and ignores the nav' do
        expect(type_for('<span class="label">Manufactured</span>')).to eq ['Manufactured']
      end

      it 'keeps both when a home genuinely carries both tags' do
        expect(type_for('<div class="tags"><li class="tag">Manufactured</li>' \
                        '<li class="tag">Modular</li></div>'))
          .to contain_exactly('Manufactured', 'Modular')
      end

      it 'strips the nav before falling back to a text scan' do
        expect(type_for('<p>This modular home sleeps six.</p>')).to eq ['Modular']
      end

      it 'ignores tags that are not a property type' do
        expect(type_for('<span class="label">New</span><span class="label">Modular</span>'))
          .to eq ['Modular']
      end
    end

    describe 'images' do
      let(:urls) { home.images.map { |i| i['source_url'] } }

      it 'excludes imagery belonging to other floor plans' do
        expect(urls).to all(include('/floorplan/231596/'))
        expect(urls.join).not_to include('223727')
      end

      it 'drops the _thumb_xxl duplicate when the full-resolution shot is present' do
        expect(urls).to include("#{cdn}/manufacturer/3391/floorplan/231596/Cahaba-1.jpg")
        expect(urls.grep(/_thumb_xxl/)).to be_empty
      end

      it 'tags the floor plan drawing' do
        expect(home.images.select { |i| i['is_floorplan'] }.map { |i| i['source_url'] })
          .to eq ["#{cdn}/manufacturer/3391/floorplan/231596/Cahaba%20CS-1604%20floor-plans-SMALL.jpg"]
      end

      it 'keeps a thumbnail that has no full-resolution sibling' do
        html = %(<html><body><img src="#{cdn}/manufacturer/3391/floorplan/231596/only_thumb_xxl.jpg" /></body></html>)
        parsed = tc_adapter.parse(key: '231596', url: 'https://x/', html: html, card: {})
        expect(parsed.images.map { |i| i['source_url'] }).to eq ["#{cdn}/manufacturer/3391/floorplan/231596/only_thumb_xxl.jpg"]
      end

      it 'falls back to every CloudFront image when none match the floor plan id' do
        html = %(<html><body><img src="#{cdn}/manufacturer/3391/floorplan/888888/a.jpg" /></body></html>)
        parsed = tc_adapter.parse(key: '231596', url: 'https://x/', html: html, card: {})
        expect(parsed.images.size).to eq 1
      end
    end
  end

  describe '#detail_url' do
    it 'uses the permalink base observed during discovery' do
      tc_discover
      expect(tc_adapter.send(:detail_url, '231596'))
        .to eq 'https://www.timbercreekhousing.com/floorplan/231596-1982/'
    end

    it 'honours an explicit detail_path when nothing has been discovered' do
      adapter = described_class.new(
        source_for('https://www.timbercreekhousing.com/dealer/1982/x/y/', { 'detail_path' => 'floorplan' })
      )
      expect(adapter.send(:detail_url, '1')).to eq 'https://www.timbercreekhousing.com/floorplan/1-1982/'
    end

    it 'defaults to /floor-plan-detail/ for an unscoped source' do
      adapter = described_class.new(source_for('https://www.sunshinehomes-inc.com/manufactured-home-floor-plans/'))
      expect(adapter.send(:detail_url, '224988')).to eq 'https://www.sunshinehomes-inc.com/floor-plan-detail/224988/'
    end
  end
end
