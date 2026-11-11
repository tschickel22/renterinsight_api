# frozen_string_literal: true

require 'rails_helper'

# Fixtures mirror jessuphousing.com: Beaver Builder home pages nested under a
# series page. Elite pages write features as "•" lines split by <br>,
# Promotional pages as <ul>; both carry a Popular Options list.
RSpec.describe Catalog::Adapters::JessupHousingAdapter do
  let(:root) { 'https://www.jessuphousing.com' }
  let(:source) do
    build(:catalog_source, adapter_type: 'jessup_housing', base_url: "#{root}/",
                           config: { 'untracked_fields' => %w[description] })
  end
  let(:adapter) { described_class.new(source) }

  let(:sitemap) do
    <<~XML
      <?xml version="1.0" encoding="UTF-8"?>
      <urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">
        <url><loc>#{root}/</loc></url>
        <url><loc>#{root}/the-elite-series/</loc></url>
        <url><loc>#{root}/the-elite-series/the-nixon/</loc></url>
        <url><loc>#{root}/the-promotional-series/bahama-28x76/</loc></url>
        <url><loc>#{root}/careers/</loc></url>
        <url><loc>#{root}/about/team/</loc></url>
      </urlset>
    XML
  end

  def heading(text, tag: 'h2')
    %(<div class="fl-module fl-module-heading"><div class="fl-module-content"><#{tag} class="fl-heading"><span class="fl-heading-text">#{text}</span></#{tag}></div></div>)
  end

  def rich(html)
    %(<div class="fl-module fl-module-rich-text"><div class="fl-module-content"><div class="fl-rich-text">#{html}</div></div></div>)
  end

  def section(title, body)
    %(<div class="fl-col"><div class="fl-col-content">#{heading(title, tag: 'h4')}#{rich(body)}</div></div>)
  end

  def page(name:, model:, spec:, features:, gallery: true, tour: '')
    gallery_html = if gallery
                     <<~HTML
                       #{heading('GALLERY')}
                       <div class="fl-module fl-module-gallery"><div class="fl-mosaicflow-item">
                         <a href="#{root}/wp-content/uploads/2026/03/kitchen.jpg"><img src="#{root}/wp-content/uploads/2026/03/kitchen-300x200.jpg"></a>
                       </div><div class="fl-mosaicflow-item">
                         <a href="#{root}/wp-content/uploads/2026/03/living.jpg"><img src="#{root}/wp-content/uploads/2026/03/living-300x200.jpg"></a>
                       </div></div>
                     HTML
                   end
    <<~HTML
      <html><head><title>#{name} - Jessup Housing</title></head><body>
      <header><img src="#{root}/wp-content/uploads/2023/03/Jessup-logo.png"></header>
      <div class="entry-content clear">
        <div class="fl-row fl-row-bg-photo" style="background-image:url(#{root}/wp-content/uploads/2023/03/the-lincoln-2-2.jpg)">
          #{heading(name)}
        </div>
        #{heading(model)}
        #{rich("<p>#{spec}</p>")}
        #{heading('FLOORPLAN')}
        <div class="fl-module fl-module-photo"><div class="fl-photo-content">
          <img class="lazyload" src="data:image/png;base64,AAAA" data-src="//www.jessuphousing.com/wp-content/uploads/2026/02/plan.png">
        </div></div>
        <div class="fl-module fl-module-button"><a class="fl-button" href="#{root}/wp-content/uploads/2026/04/Jessup-Plan.pdf"><span>Download Floorplan</span></a></div>
        #{gallery_html}
        #{tour}
        #{heading('FEATURES')}
        #{features}
      </div></body></html>
    HTML
  end

  let(:elite) do
    page(name: 'THE NIXON', model: 'SPS16682A', spec: '2 Bed | 2 Bath | 1,065 Square Feet',
         tour: '<div id="virtualtour"><iframe src="https://my.matterport.com/models/UGTWSnzvbrc?cta_origin=model_listing_results"></iframe></div>',
         features: section('EXTERIOR', '<p>• Low E Windows<br /> • Craftsman Style Front Door<br /></p>') +
                   section('KITCHEN', '<p>• Farmhouse Kitchen Sink</p>') +
                   section('POPULAR OPTIONS', '<ul><li>Stainless Steel Appliances</li><li>Gas Furnace</li></ul>'))
  end

  let(:promo) do
    page(name: 'BAHAMA 28X76', model: 'FAC28765A', spec: '5 Bed | 3 Bath | 2001 Square Feet', gallery: false,
         features: section('EXTERIOR', '<ul><li>Dormer</li><li>Blank Rear Door</li></ul>') +
                   section('POPULAR OPTIONS', '<ul><li>Wind Zone 2</li></ul>'))
  end

  def parse(html, key:, path:)
    adapter.parse(key: key, url: "#{root}#{path}", html: html)
  end

  describe '#discover' do
    it 'keeps only home pages nested under a series page, keyed by slug' do
      allow(adapter).to receive(:http_get).and_return(sitemap)
      expect(adapter.discover).to eq(%w[the-nixon bahama-28x76])
      expect(adapter.discover(limit: 1)).to eq(%w[the-nixon])
    end

    it 'raises rather than report an empty catalog when the sitemap is unreachable' do
      allow(adapter).to receive(:http_get).and_return(nil)
      expect { adapter.discover }.to raise_error(/no sitemap/)
    end
  end

  describe '#fetch' do
    it 'fetches the URL discovery found for the key' do
      allow(adapter).to receive(:http_get).with(/page-sitemap/, any_args).and_return(sitemap)
      adapter.discover
      allow(adapter).to receive(:http_get).with("#{root}/the-elite-series/the-nixon/").and_return(elite)
      expect(adapter.fetch('the-nixon')).to include(key: 'the-nixon', html: elite)
    end
  end

  describe '#parse' do
    subject(:home) { parse(elite, key: 'the-nixon', path: '/the-elite-series/the-nixon/') }

    it 'reads the specs from the page' do
      expect(home).to have_attributes(source_key: 'the-nixon', model_name: 'The Nixon', model_id: 'SPS16682A',
                                      series: 'Elite Series', bedrooms: 2, bathrooms: '2', square_feet: 1065)
    end

    it 'reads width and length from the model number when the name has no size' do
      expect(home.dimensions).to eq('16x68')
      expect(home.property_type).to eq(['Single Wide'])
    end

    it 'puts the floor plan first, flagged, then the full size gallery, and skips the hero and logo' do
      expect(home.images.map { |i| [i['source_url'].split('/').last, i['is_floorplan']] })
        .to eq([['plan.png', true], ['kitchen.jpg', false], ['living.jpg', false]])
      expect(home.images.first['source_url']).to start_with('https://')
    end

    it 'reads bullet-line features by section and keeps popular options out of them' do
      expect(home.features).to eq('Exterior' => ['Low E Windows', 'Craftsman Style Front Door'],
                                  'Kitchen' => ['Farmhouse Kitchen Sink'])
      expect(home.raw['popular_options']).to eq(['Stainless Steel Appliances', 'Gas Furnace'])
      expect(home.raw['floorplan_pdf_url']).to end_with('Jessup-Plan.pdf')
    end

    it 'normalizes the Matterport tour to its embeddable link' do
      expect(home.virtual_tour_url).to eq('https://my.matterport.com/show/?m=UGTWSnzvbrc')
    end

    it 'passes the smoke check with description untracked' do
      expect(home.valid_smoke?(untracked: %w[description])).to be(true)
    end

    context 'with a Promotional home whose name carries its size' do
      subject(:home) { parse(promo, key: 'bahama-28x76', path: '/the-promotional-series/bahama-28x76/') }

      it 'drops the size from the name, uses it as the dimensions and reads list features' do
        expect(home).to have_attributes(model_name: 'Bahama', model_id: 'FAC28765A', series: 'Promotional Series',
                                        dimensions: '28x76', property_type: ['Double Wide'], bedrooms: 5)
        expect(home.features).to eq('Exterior' => ['Dormer', 'Blank Rear Door'])
      end

      it 'still has an image when the gallery is empty, and no tour' do
        expect(home.images.map { |i| i['is_floorplan'] }).to eq([true])
        expect(home.virtual_tour_url).to be_nil
      end
    end
  end

  it 'is registered and named' do
    expect(Catalog::AdapterRegistry.for(source)).to be_a(described_class)
    expect(Catalog::ManufacturerName.for(source)).to eq('Jessup Housing')
  end
end
