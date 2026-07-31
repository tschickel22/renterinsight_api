# frozen_string_literal: true

require 'rails_helper'

RSpec.describe SiteProfiles::VendorDetector do
  def digest_for(html, url: 'https://sunshinehomes.example/')
    response = SiteProfiles::Fetcher::Response.new(
      url: url, status: 200, body: html, content_type: 'text/html'
    )
    SiteProfiles::PageDigest.new(response).call
  end

  def detect(html, **kwargs)
    described_class.new([digest_for(html)], **kwargs).call
  end

  describe 'dispositions' do
    it 'maps GTM onto a typed tracking field and extracts the container id' do
      d = detect(<<~HTML).find { |x| x.vendor == 'Google Tag Manager' }
        <html><head>
        <script src="https://www.googletagmanager.com/gtm.js?id=GTM-ABC1234"></script>
        </head><body></body></html>
      HTML

      expect(d.disposition).to eq('mapped')
      expect(d.config_key).to eq('google_tag_manager_id')
      expect(d.value).to eq('GTM-ABC1234')
    end

    it 're-embeds a chat widget rather than mapping it' do
      d = detect(<<~HTML).find { |x| x.vendor == 'Tawk.to' }
        <html><body>
        <script src="https://embed.tawk.to/5f1a/default"></script>
        </body></html>
      HTML

      expect(d.disposition).to eq('re_embed')
      expect(d.category).to eq('chat')
      expect(d.config_key).to be_nil
    end

    it 'treats a pre-approval link as a CTA and keeps its anchor text' do
      d = detect(<<~HTML).find { |x| x.vendor == '700Credit' }
        <html><body>
        <a href="https://www.700credit.com/apply/sunshine">Get Pre-Approved in 60 Seconds</a>
        </body></html>
      HTML

      expect(d.disposition).to eq('link_out')
      expect(d.category).to eq('financing')
      expect(d.label).to eq('Get Pre-Approved in 60 Seconds')
    end

    it 'drops a legacy inventory widget that our own block supersedes' do
      d = detect(<<~HTML).find { |x| x.vendor == 'MHVillage' }
        <html><body>
        <iframe src="https://www.mhvillage.com/embed/dealer/1234"></iframe>
        </body></html>
      HTML

      expect(d.disposition).to eq('drop')
    end
  end

  describe 'id extraction from inline bootstraps' do
    it 'pulls a Meta Pixel id out of an inline fbq init' do
      d = detect(<<~HTML).find { |x| x.vendor == 'Meta Pixel' }
        <html><head>
        <script>!function(f,b,e,v,n,t,s){}(window);fbq('init', '123456789012345');fbq('track','PageView');</script>
        <script src="https://connect.facebook.net/en_US/fbevents.js"></script>
        </head><body></body></html>
      HTML

      expect(d.value).to eq('123456789012345')
    end

    it 'finds a GA4 measurement id' do
      d = detect(<<~HTML).find { |x| x.vendor == 'Google Analytics' }
        <html><head>
        <script src="https://www.googletagmanager.com/gtag/js?id=G-XYZ987"></script>
        </head><body></body></html>
      HTML

      expect(d.value).to eq('G-XYZ987')
    end
  end

  describe 'unknown third parties' do
    it 'surfaces an unrecognised iframe rather than silently dropping it' do
      d = detect(<<~HTML).find { |x| x.category == 'unknown' }
        <html><body>
        <iframe src="https://widget.someunknownvendor.io/embed/42"></iframe>
        </body></html>
      HTML

      expect(d).not_to be_nil
      expect(d.vendor).to eq('widget.someunknownvendor.io')
      expect(d.disposition).to eq('re_embed')
    end

    it 'ignores ubiquitous furniture like maps and video' do
      results = detect(<<~HTML)
        <html><body>
        <iframe src="https://www.google.com/maps/embed?pb=x"></iframe>
        <iframe src="https://www.youtube.com/embed/abc123"></iframe>
        </body></html>
      HTML

      expect(results.select { |d| d.category == 'unknown' }).to be_empty
    end

    it 'ignores the site being scanned' do
      results = detect(<<~HTML, source_host: 'sunshinehomes.example')
        <html><body>
        <iframe src="https://sunshinehomes.example/tour/1"></iframe>
        </body></html>
      HTML

      expect(results.select { |d| d.category == 'unknown' }).to be_empty
    end
  end

  describe 'host anchoring' do
    # Regression: a bare /homes\.com/ also matches championhomes.com, which
    # dropped a manufacturer link as if it were a competitor inventory widget.
    it 'does not match a vendor domain appearing as a substring of another host' do
      expect(SiteProfiles::VendorSignatures.match('https://championhomes.com/')).to be_nil
      expect(SiteProfiles::VendorSignatures.match('https://palmharborhomes.com/')).to be_nil
      expect(SiteProfiles::VendorSignatures.match('https://spendthrift.com/')).to be_nil
    end

    it 'still matches the real vendor hosts and their subdomains' do
      expect(SiteProfiles::VendorSignatures.match('https://www.homes.com/x')&.vendor).to eq('HomesDirect')
      expect(SiteProfiles::VendorSignatures.match('https://embed.tawk.to/abc')&.vendor).to eq('Tawk.to')
      expect(SiteProfiles::VendorSignatures.match('https://www.700credit.com/apply')&.vendor).to eq('700Credit')
    end
  end

  it 'deduplicates a vendor seen on several pages, keeping the one with an id' do
    with_id = digest_for(<<~HTML)
      <html><head><script src="https://www.googletagmanager.com/gtm.js?id=GTM-KEEPME"></script></head><body></body></html>
    HTML
    without_id = digest_for(<<~HTML)
      <html><head><script src="https://www.googletagmanager.com/gtm.js"></script></head><body></body></html>
    HTML

    results = described_class.new([without_id, with_id]).call
    gtm = results.select { |d| d.vendor == 'Google Tag Manager' }

    expect(gtm.size).to eq(1)
    expect(gtm.first.value).to eq('GTM-KEEPME')
  end
end
