# frozen_string_literal: true

require 'rails_helper'

# The typed ids have been collected since the website form was built and emitted
# nowhere: permitted in params, filled in by dealers, detected by the site
# scanner, and never turned into a script tag. A dealer who entered their GA4 id
# got a saved value and no analytics.
RSpec.describe Websites::TrackingTags do
  let(:company) { Company.create!(name: "Co-#{SecureRandom.hex(3)}") }
  let(:location) { company.locations.create!(name: 'Main') }

  def site(config)
    Website.create!(company_id: company.id, location_id: location.id, name: 'S',
                    slug: "s-#{SecureRandom.hex(3)}", status: 'published',
                    tracking_config: config)
  end

  def page_on(website, config)
    website.website_pages.create!(title: 'FB', path: '/fb', page_kind: 'landing',
                                  blocks: [], tracking_config: config)
  end

  describe 'the vendors it can write a snippet for' do
    it 'emits GA4 from an id alone' do
      result = described_class.new(website: site('google_analytics_id' => 'G-ABC12345')).call

      expect(result.head).to include('googletagmanager.com/gtag/js?id=G-ABC12345')
      expect(result.head).to include("gtag('config', 'G-ABC12345')")
    end

    it 'emits both halves of Google Tag Manager' do
      result = described_class.new(website: site('google_tag_manager_id' => 'GTM-ABC123')).call

      expect(result.head).to include('gtm.js?id=')
      # Pointless for a visitor running JavaScript and required by Google's own
      # instructions, so it goes in rather than being judged.
      expect(result.body).to include('googletagmanager.com/ns.html?id=GTM-ABC123')
    end

    it 'emits the Meta pixel with its PageView and its noscript image' do
      result = described_class.new(website: site('facebook_pixel_id' => '1234567890')).call

      expect(result.head).to include("fbq('init', '1234567890')")
      expect(result.head).to include("fbq('track', 'PageView')")
      expect(result.head).to include('facebook.com/tr?id=1234567890')
    end

    it 'emits Hotjar' do
      result = described_class.new(website: site('hotjar_id' => '1234567')).call

      expect(result.head).to include('hjid:1234567')
    end

    # A mistyped id produces a snippet that silently does nothing and a console
    # error, which is harder to diagnose than no snippet at all.
    it 'skips an id that is not shaped like its vendor and still emits the rest' do
      result = described_class.new(
        website: site('google_analytics_id' => 'not-an-id', 'facebook_pixel_id' => '1234567890')
      ).call

      expect(result.head).not_to include('gtag/js')
      expect(result.head).to include("fbq('init'")
    end

    it 'emits nothing at all when nothing is configured' do
      result = described_class.new(website: site({})).call

      expect(result.head).to be_nil
      expect(result.body).to be_nil
    end
  end

  describe 'a landing page over its container' do
    let(:container) do
      site('google_tag_manager_id' => 'GTM-SITE01',
           'facebook_pixel_id' => '1111111111',
           'custom_scripts' => { 'head' => '<meta name="site-level">' })
    end

    it 'lets the page override an id the site also sets' do
      page = page_on(container, 'facebook_pixel_id' => '2222222222')
      result = described_class.new(website: container, page: page).call

      expect(result.head).to include("fbq('init', '2222222222')")
      expect(result.head).not_to include('1111111111')
    end

    it 'keeps a site id the page does not mention' do
      page = page_on(container, 'facebook_pixel_id' => '2222222222')
      result = described_class.new(website: container, page: page).call

      expect(result.head).to include('gtm.js?id=')
    end

    # The usual arrangement is one site-wide container plus a per-campaign
    # pixel. Replacing rather than adding would switch off analytics on the page
    # that most needs it.
    it 'runs both custom snippets rather than replacing the site\'s' do
      page = page_on(container, 'custom_scripts' => { 'head' => '<meta name="page-level">' })
      result = described_class.new(website: container, page: page).call

      expect(result.head).to include('site-level')
      expect(result.head).to include('page-level')
    end

    it 'ignores a blank page value rather than blanking the site id' do
      page = page_on(container, 'facebook_pixel_id' => '')
      result = described_class.new(website: container, page: page).call

      expect(result.head).to include("fbq('init', '1111111111')")
    end
  end
end
