# frozen_string_literal: true

require 'rails_helper'

RSpec.describe SiteProfiles::Renderer do
  around do |example|
    original = ENV.to_hash.slice('SITE_SCAN_RENDERER', 'SITE_SCAN_RENDER_TOKEN', 'SITE_SCAN_RENDER_URL')
    example.run
    %w[SITE_SCAN_RENDERER SITE_SCAN_RENDER_TOKEN SITE_SCAN_RENDER_URL].each { |k| ENV.delete(k) }
    original.each { |k, v| ENV[k] = v }
  end

  def configure(provider: 'browserless', token: 'key_1')
    ENV['SITE_SCAN_RENDERER'] = provider
    ENV['SITE_SCAN_RENDER_TOKEN'] = token
  end

  describe '.enabled?' do
    it 'is off when nothing is configured' do
      ENV.delete('SITE_SCAN_RENDERER')
      expect(described_class).not_to be_enabled
    end

    it 'is off when a provider is named without a key' do
      ENV['SITE_SCAN_RENDERER'] = 'browserless'
      ENV.delete('SITE_SCAN_RENDER_TOKEN')
      expect(described_class).not_to be_enabled
    end

    it 'is off for a provider we do not speak' do
      configure(provider: 'something-else')
      expect(described_class).not_to be_enabled
    end

    it 'is on once a known provider and a key are set' do
      configure
      expect(described_class).to be_enabled
    end
  end

  describe '#call' do
    it 'returns nothing at all when rendering is off' do
      ENV.delete('SITE_SCAN_RENDERER')
      expect(described_class.new.call('https://dealer.com/')).to be_nil
    end

    it 'hands back the rendered document' do
      configure
      stub_http(Net::HTTPSuccess, '<html><body><h1>Sunshine Homes</h1></body></html>')

      expect(described_class.new.call('https://dealer.com/')).to include('Sunshine Homes')
    end

    # The provider seeing the same wall we did is not a rendering. Passing it on
    # would put a security interstitial into the dealer's profile, which is the
    # exact bug the renderer exists to prevent.
    it 'refuses a challenge page the provider passed through' do
      configure
      stub_http(Net::HTTPSuccess, '<html><head><title>Vercel Security Checkpoint</title></head></html>')

      expect(described_class.new.call('https://dealer.com/')).to be_nil
    end

    it 'gives up quietly when the provider errors' do
      configure
      stub_http(Net::HTTPServerError, 'upstream exploded')

      expect(described_class.new.call('https://dealer.com/')).to be_nil
    end

    it 'gives up quietly when the provider is unreachable' do
      configure
      allow_any_instance_of(Net::HTTP).to receive(:request).and_raise(Errno::ECONNREFUSED)

      expect(described_class.new.call('https://dealer.com/')).to be_nil
    end
  end

  # The bug this guard was added for, and then lost.
  #
  # The chrome branch returned local_browser.render(url) directly, jumping the
  # challenge check below it. In production that meant a Vercel checkpoint which
  # never cleared came back as a successful render, so the scan built a profile
  # from an interstitial and failed with a message blaming JavaScript.
  describe 'local chrome' do
    let(:browser) { instance_double(SiteProfiles::LocalBrowser, available?: true, diagnostic: nil) }

    before do
      configure(provider: 'chrome', token: nil)
      ENV.delete('SITE_SCAN_RENDER_TOKEN')
      allow(SiteProfiles::LocalBrowser).to receive(:new).and_return(browser)
    end

    it 'needs no API key' do
      expect(described_class).to be_enabled
    end

    it 'passes a real page through' do
      allow(browser).to receive(:render).and_return('<html><body><h1>Sunshine Homes</h1></body></html>')

      renderer = described_class.new
      expect(renderer.call('https://dealer.com/')).to include('Sunshine Homes')
      expect(renderer.last_outcome).to eq(:rendered)
    end

    it 'refuses a checkpoint the browser could not clear' do
      allow(browser).to receive(:render)
        .and_return('<html><head><title>Vercel Security Checkpoint</title></head></html>')

      renderer = described_class.new
      expect(renderer.call('https://dealer.com/')).to be_nil
      expect(renderer.last_outcome).to eq(:still_challenged)
    end

    it 'reports a browser that would not start, rather than an empty page' do
      allow(browser).to receive(:render).and_return(nil)
      allow(browser).to receive(:available?).and_return(false)

      renderer = described_class.new
      expect(renderer.call('https://dealer.com/')).to be_nil
      expect(renderer.last_outcome).to eq(:unavailable)
    end
  end

  def stub_http(response_class, body)
    response = instance_double(response_class, body: body)
    allow(response).to receive(:is_a?) { |klass| klass == response_class || klass == Net::HTTPResponse }
    allow_any_instance_of(Net::HTTP).to receive(:request).and_return(response)
  end
end
