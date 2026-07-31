# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'SiteProfiles extraction' do
  def digest_for(html, url: 'https://sunshinehomes.example/')
    response = SiteProfiles::Fetcher::Response.new(
      url: url, status: 200, body: html, content_type: 'text/html'
    )
    SiteProfiles::PageDigest.new(response).call
  end

  describe SiteProfiles::PageDigest do
    let(:html) do
      <<~HTML
        <html><head>
          <title>Sunshine Homes of Denver</title>
          <meta name="description" content="Quality manufactured homes in Colorado.">
          <meta property="og:image" content="/img/hero.jpg">
        </head><body>
          <h1>Your Dream Home Awaits</h1>
          <h2>Why Buy From Us</h2>
          <p>We have served Colorado families for over thirty years with quality homes and honest pricing.</p>
          <p>Short</p>
          <img src="/img/logo.png" alt="Sunshine Homes logo">
          <a href="/inventory">Browse Homes</a>
          <form action="/contact" method="post">
            <input name="full_name" type="text" placeholder="Your name" required>
            <input name="email" type="email" placeholder="Email">
            <input name="csrf" type="hidden">
          </form>
          <script src="https://embed.tawk.to/abc"></script>
          <style>.x { color: #123456 }</style>
        </body></html>
      HTML
    end

    it 'extracts the page essentials' do
      d = digest_for(html)
      expect(d.title).to eq('Sunshine Homes of Denver')
      expect(d.meta_description).to eq('Quality manufactured homes in Colorado.')
      expect(d.og_image).to eq('/img/hero.jpg')
      expect(d.headings.map { |h| h[:text] }).to include('Your Dream Home Awaits', 'Why Buy From Us')
    end

    it 'keeps prose and skips fragments too short to be content' do
      d = digest_for(html)
      expect(d.paragraphs.first).to match(/served Colorado families/)
      expect(d.paragraphs).not_to include('Short')
    end

    it 'resolves relative urls against the page' do
      d = digest_for(html)
      expect(d.images.first[:src]).to eq('https://sunshinehomes.example/img/logo.png')
      expect(d.links.first[:href]).to eq('https://sunshinehomes.example/inventory')
    end

    it 'captures form fields but not hidden ones' do
      fields = digest_for(html).forms.first[:fields]
      expect(fields.map { |f| f[:name] }).to contain_exactly('full_name', 'email')
      expect(fields.first[:required]).to be(true)
    end

    it 'captures scripts before stripping them from the text' do
      d = digest_for(html)
      expect(d.scripts[:external]).to include('https://embed.tawk.to/abc')
    end

    it 'flags a client-rendered shell' do
      spa = digest_for(<<~HTML)
        <html><head><title>App</title></head>
        <body><div id="root"></div>
        <script src="/assets/index-abc123.js"></script>
        #{'<div class="a b c d e f g h i j k l m n o p"></div>' * 200}
        </body></html>
      HTML
      expect(spa).to be_likely_client_rendered
      expect(digest_for(html)).not_to be_likely_client_rendered
    end
  end

  describe SiteProfiles::BrandExtractor do
    it 'prefers a declared CSS custom property for the brand colour' do
      brand = described_class.new([{
        url: 'https://sunshinehomes.example/',
        html: '<html><head><style>:root{--primary-color:#059669;--secondary-color:#64748b}</style></head><body></body></html>'
      }]).call

      expect(brand['colors']['primary']).to eq('#059669')
      expect(brand['colors']['secondary']).to eq('#64748b')
    end

    it 'falls back to the dominant non-neutral colour and ignores greys' do
      css = ('.a{color:#333333}' * 30) + ('.b{color:#ffffff}' * 30) + ('.c{color:#b91c1c}' * 5)
      brand = described_class.new([{
        url: 'https://x.example/', html: "<html><head><style>#{css}</style></head><body></body></html>"
      }]).call

      expect(brand['colors']['primary']).to eq('#b91c1c')
    end

    it 'expands shorthand hex and converts rgb()' do
      brand = described_class.new([{
        url: 'https://x.example/',
        html: '<html><head><style>:root{--primary:#0a0;--secondary:rgb(37, 99, 235)}</style></head><body></body></html>'
      }]).call

      expect(brand['colors']['primary']).to eq('#00aa00')
      expect(brand['colors']['secondary']).to eq('#2563eb')
    end

    it 'finds the logo by class hint' do
      brand = described_class.new([{
        url: 'https://sunshinehomes.example/',
        html: '<html><body><header><img class="site-logo" src="/img/brand.png"></header></body></html>'
      }]).call

      expect(brand['logo_url']).to eq('https://sunshinehomes.example/img/brand.png')
    end

    it 'reads the font from a Google Fonts link' do
      brand = described_class.new([{
        url: 'https://x.example/',
        html: '<html><head><link href="https://fonts.googleapis.com/css2?family=Open+Sans:wght@400&display=swap"></head><body></body></html>'
      }]).call

      expect(brand['fonts']['heading']).to eq('Open Sans')
    end
  end

  describe SiteProfiles::LinkInventory do
    let(:inventory) do
      digest = digest_for(<<~HTML)
        <html><body>
          <a href="/inventory">Browse Homes</a>
          <a href="/financing">Financing</a>
          <a href="/about-us">About Us</a>
          <a href="https://sunshinehomes.example/contact">Contact</a>
          <a href="https://www.700credit.com/apply">Get Pre-Approved in 60 Seconds</a>
          <a href="https://facebook.com/sunshinehomes">Facebook</a>
          <a href="https://championhomes.com">Champion Homes</a>
          <a href="/brochure.pdf">Download brochure</a>
        </body></html>
      HTML
      described_class.new([digest], base_url: 'https://sunshinehomes.example/').call
    end

    it 'classifies internal pages by role' do
      roles = inventory['internal'].to_h { |e| [e['path'], e['page_role']] }
      expect(roles['/inventory']).to eq('inventory')
      expect(roles['/financing']).to eq('financing')
      expect(roles['/about-us']).to eq('about')
      expect(roles['/contact']).to eq('contact')
    end

    it 'treats same-host absolute links as internal' do
      expect(inventory['internal'].map { |e| e['path'] }).to include('/contact')
    end

    it 'keeps external links WITH the anchor text that explains them' do
      lender = inventory['external'].find { |e| e['href'].include?('700credit') }
      expect(lender['category']).to eq('financing')
      expect(lender['context']).to eq('Get Pre-Approved in 60 Seconds')
    end

    it 'categorises social and manufacturer links' do
      categories = inventory['external'].to_h { |e| [e['href'], e['category']] }
      expect(categories['https://facebook.com/sunshinehomes']).to eq('social')
      expect(categories['https://championhomes.com']).to eq('manufacturer')
    end

    it 'skips file downloads' do
      expect(inventory['internal'].map { |e| e['path'] }).not_to include('/brochure.pdf')
    end
  end
end
