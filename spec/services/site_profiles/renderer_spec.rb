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

  def stub_http(response_class, body)
    response = instance_double(response_class, body: body)
    allow(response).to receive(:is_a?) { |klass| klass == response_class || klass == Net::HTTPResponse }
    allow_any_instance_of(Net::HTTP).to receive(:request).and_return(response)
  end
end
