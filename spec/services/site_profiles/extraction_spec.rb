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
          <img src="/img/lot-photo.jpg" alt="Homes on our lot">
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
      expect(d.images.first[:src]).to eq('https://sunshinehomes.example/img/lot-photo.jpg')
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

    describe 'tuning against real dealer markup' do
      # ~75% of <li> on a dealer home page are menu items, so reading "every p
      # and li" yields mostly navigation.
      it 'ignores navigation when reading prose' do
        d = digest_for(<<~HTML)
          <html><body>
            <nav><ul><li>Floor Plans</li><li>Singlewides</li><li>Doublewides</li></ul></nav>
            <footer><p>Builders Clayton Homes TRU Homes Champion Homes Legacy Homes Marathon</p></footer>
            <div><p>We have served East Texas families since 1999 with quality manufactured homes.</p></div>
          </body></html>
        HTML

        expect(d.paragraphs.size).to eq(1)
        expect(d.paragraphs.first).to match(/East Texas families/)
      end

      # Nokogiri's #text runs adjacent elements together: "WELCOME TO" +
      # "MOBILE HOME MASTERS" became "WELCOME TOMOBILE HOME MASTERS".
      it 'separates nested heading elements instead of running them together' do
        d = digest_for('<html><body><h1><span>WELCOME TO</span><span>MOBILE HOME MASTERS</span></h1></body></html>')
        expect(d.headings.first[:text]).to eq('WELCOME TO MOBILE HOME MASTERS')
      end

      # Elementor and friends put the good photography in CSS, not <img>.
      it 'collects hero imagery from inline background-image' do
        d = digest_for(<<~HTML)
          <html><body>
            <div style="background-image: url('/img/hero-lot.jpg')"></div>
            <section style='background:#fff url("/img/section.jpg") no-repeat'></section>
          </body></html>
        HTML

        expect(d.background_images).to include('https://sunshinehomes.example/img/hero-lot.jpg')
        expect(d.background_images).to include('https://sunshinehomes.example/img/section.jpg')
        expect(d.candidate_hero_images.first).to eq('https://sunshinehomes.example/img/hero-lot.jpg')
      end

      it 'skips logos, icons and spacers when collecting photography' do
        d = digest_for(<<~HTML)
          <html><body>
            <img src="/img/header-logo.png" alt="Logo">
            <img src="/img/facebook-icon.svg" alt="Social">
            <img src="/img/spacer.gif" width="1">
            <img src="/img/real-home.jpg" alt="A home">
          </body></html>
        HTML

        expect(d.images.map { |i| i[:src] }).to eq(['https://sunshinehomes.example/img/real-home.jpg'])
      end

      # A real scan pulled several 4KB WordPress thumbnails, which would look
      # awful stretched across a hero band.
      it 'skips generated thumbnails' do
        d = digest_for(<<~HTML)
          <html><body>
            <img src="/img/home-150x150.jpg" alt="a">
            <img src="/img/plans-small_thumb.jpg" alt="b">
            <img src="/img/real-hero-photo.jpg" alt="c">
          </body></html>
        HTML

        expect(d.images.map { |i| File.basename(i[:src]) }).to eq(['real-hero-photo.jpg'])
      end

      # A 4th-of-July banner was the first background on a real dealer home
      # page, so hero_images[0] put fireworks behind the headline.
      #
      # Demoting was not enough. A demoted image still reached hero_images, and
      # reaching it at all is sufficient — a hero band renders index 0 of
      # whatever list it is handed, and merging across pages reshuffled the
      # order anyway. Promotional graphics are now excluded from the hero
      # candidates outright and offered separately for galleries.
      it 'keeps seasonal and promotional graphics out of the hero candidates' do
        d = digest_for(<<~HTML)
          <html><body>
            <div style="background-image: url('/img/july4-sale-banner.jpg')"></div>
            <div style="background-image: url('/img/lot-exterior.jpg')"></div>
          </body></html>
        HTML

        expect(d.candidate_hero_images).to eq(['https://sunshinehomes.example/img/lot-exterior.jpg'])
        # Still available for galleries, just never behind a headline.
        expect(d.demoted_images.join).to match(/july4/)
      end

      # The specific image that prompted all of this: a dealer's American flag,
      # reused across every seasonal campaign and therefore the most-linked
      # image on the site.
      it 'keeps patriotic decoration out of the hero candidates' do
        d = digest_for(<<~HTML)
          <html><body>
            <div style="background-image: url('/img/usa-stars-and-stripes.jpg')"></div>
            <div style="background-image: url('/img/model-home-exterior.jpg')"></div>
          </body></html>
        HTML

        expect(d.candidate_hero_images.join).not_to match(/stars-and-stripes/)
        expect(d.candidate_hero_images.join).to match(/model-home-exterior/)
      end

      # A dealer trading as "American Homes of Texas" must not have their own
      # photography demoted by the patriotic filter.
      it 'does not demote a dealer whose name merely contains American' do
        d = digest_for(<<~HTML)
          <html><body>
            <div style="background-image: url('/img/american-homes-of-texas-exterior.jpg')"></div>
          </body></html>
        HTML

        expect(d.candidate_hero_images.join).to match(/american-homes-of-texas/)
      end

      # Financing badges, review widgets and staff photos are not homes.
      it 'keeps non-home furniture out of the hero candidates' do
        d = digest_for(<<~HTML)
          <html><body>
            <div style="background-image: url('/img/handshake-financing.jpg')"></div>
            <div style="background-image: url('/img/our-team-photo.jpg')"></div>
            <div style="background-image: url('/img/singlewide-exterior.jpg')"></div>
          </body></html>
        HTML

        expect(d.candidate_hero_images).to eq(['https://sunshinehomes.example/img/singlewide-exterior.jpg'])
      end

      it 'takes the widest candidate from srcset' do
        d = digest_for(<<~HTML)
          <html><body><img srcset="/img/small.jpg 400w, /img/large.jpg 1600w" alt="Home"></body></html>
        HTML

        expect(d.images.first[:src]).to eq('https://sunshinehomes.example/img/large.jpg')
      end
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

  describe SiteProfiles::BrandExtractor do
    def extract(css_or_html)
      html = css_or_html.include?('<') ? css_or_html : "<html><head><style>#{css_or_html}</style></head><body></body></html>"
      described_class.new([{ url: 'https://dealer.example/', html: html }]).call
    end

    # WordPress and Elementor ship generic --primary: #000 and --secondary: #fff,
    # so a dealer whose brand is a strong blue came back as black and white.
    # The footer takes its background from the secondary, so an extracted
    # #ffffff produced a white-on-white footer.
    it 'ignores neutral CSS variables and finds the real brand colour' do
      css = <<~CSS
        :root { --primary: #000000; --secondary: #ffffff; }
        .a { color: #1e99fb } .b { background: #1e99fb } .c { border-color: #1e99fb }
      CSS

      colors = extract(css)['colors']

      expect(colors['primary']).to eq('#1e99fb')
      expect(colors['secondary']).to be_nil
    end

    it 'keeps a CSS variable that is a real colour' do
      colors = extract(':root { --primary: #1e99fb; --secondary: #f97316; }')['colors']

      expect(colors['primary']).to eq('#1e99fb')
      expect(colors['secondary']).to eq('#f97316')
    end

    # A lazy-loaded logo carries only data-src, or a placeholder in src. The
    # fallback for that was unreachable, guarded by a condition requiring src.
    it 'takes a lazy-loaded logo from data-src' do
      html = '<html><body><header><img data-src="/img/site-logo.png"></header></body></html>'

      expect(extract(html)['logo_url']).to eq('https://dealer.example/img/site-logo.png')
    end

    it 'skips an inline placeholder in src' do
      html = '<html><body><header><img src="data:image/gif;base64,R0lGOD" data-src="/img/logo.png"></header></body></html>'

      expect(extract(html)['logo_url']).to eq('https://dealer.example/img/logo.png')
    end
  end
end
