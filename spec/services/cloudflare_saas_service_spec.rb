# frozen_string_literal: true

require 'rails_helper'

RSpec.describe CloudflareSaasService do
  around do |example|
    original = ENV.to_h.slice('CLOUDFLARE_ZONE_ID', 'CLOUDFLARE_API_TOKEN',
                              'CLOUDFLARE_CUSTOM_HOSTNAME_FALLBACK_ORIGIN')
    example.run
    %w[CLOUDFLARE_ZONE_ID CLOUDFLARE_API_TOKEN CLOUDFLARE_CUSTOM_HOSTNAME_FALLBACK_ORIGIN].each do |k|
      original.key?(k) ? ENV[k] = original[k] : ENV.delete(k)
    end
  end

  def configure!
    ENV['CLOUDFLARE_ZONE_ID'] = 'zone123'
    ENV['CLOUDFLARE_API_TOKEN'] = 'token123'
    ENV['CLOUDFLARE_CUSTOM_HOSTNAME_FALLBACK_ORIGIN'] = 'origin.mydealertide.com'
  end

  # Regression guard. This was https://api.cloudflare.com/v4, which makes every call return
  # {"code":10404,"message":"No route for that URI"} — an error that reads like a bad
  # endpoint or a permissions problem rather than a wrong base path.
  it 'points at Cloudflare\'s real REST base' do
    expect(described_class.base_uri).to eq('https://api.cloudflare.com/client/v4')
  end

  describe '.configured?' do
    it 'is false when nothing is set' do
      %w[CLOUDFLARE_ZONE_ID CLOUDFLARE_API_TOKEN CLOUDFLARE_CUSTOM_HOSTNAME_FALLBACK_ORIGIN]
        .each { |k| ENV.delete(k) }
      allow(Rails.application.credentials).to receive(:dig).and_return(nil)

      expect(described_class.configured?).to be false
    end

    it 'is true once all three are set' do
      configure!

      expect(described_class.configured?).to be true
    end

    it 'is false when only some are set, and names what is missing' do
      ENV['CLOUDFLARE_ZONE_ID'] = 'zone123'
      ENV.delete('CLOUDFLARE_API_TOKEN')
      ENV.delete('CLOUDFLARE_CUSTOM_HOSTNAME_FALLBACK_ORIGIN')
      allow(Rails.application.credentials).to receive(:dig).and_return(nil)

      expect(described_class.configured?).to be false
      expect { described_class.new }
        .to raise_error(described_class::CloudflareError, /CLOUDFLARE_API_TOKEN/)
    end
  end

  describe '#revalidate_custom_hostname' do
    before { configure! }

    # Reading the status triggers nothing on Cloudflare's side, so a tenant who has just
    # published the missing record would sit on a stale "pending" with no way to ask again.
    it 'patches the hostname, which is what prompts Cloudflare to re-check' do
      expect(described_class).to receive(:patch) do |path, opts|
        expect(path).to eq('/zones/zone123/custom_hostnames/cf-abc')
        expect(JSON.parse(opts[:body])).to eq('ssl' => { 'method' => 'http', 'type' => 'dv' })
        instance_double(HTTParty::Response, success?: true, body: '{"success":true}')
      end
      allow_any_instance_of(described_class).to receive(:handle_response).and_return({})

      expect(described_class.new.revalidate_custom_hostname('cf-abc')).to be true
    end

    it 'reports failure without raising, so reading the status still happens' do
      allow(described_class).to receive(:patch).and_return(
        instance_double(HTTParty::Response, success?: false, body: '{"errors":[{"message":"nope"}]}')
      )

      expect(described_class.new.revalidate_custom_hostname('cf-abc')).to be false
    end
  end

  describe '#create_worker_route' do
    around do |example|
      original = ENV['CLOUDFLARE_WORKER_SCRIPT']
      example.run
      original ? ENV['CLOUDFLARE_WORKER_SCRIPT'] = original : ENV.delete('CLOUDFLARE_WORKER_SCRIPT')
    end

    before { configure! }

    # Workers Routes match hostname patterns within the zone, and a dealer domain is a
    # custom hostname rather than a subdomain of it, so a wildcard route on the zone never
    # reaches it. Without a route per hostname the Worker does not run and Render answers
    # 403, and adding them by hand per dealer is not a product.
    it 'creates a route for the dealer hostname' do
      ENV['CLOUDFLARE_WORKER_SCRIPT'] = 'tenant-host-proxy'
      expect(described_class).to receive(:post) do |path, opts|
        expect(path).to eq('/zones/zone123/workers/routes')
        expect(JSON.parse(opts[:body])).to eq(
          'pattern' => 'www.sunshine-rv.com/*', 'script' => 'tenant-host-proxy'
        )
        instance_double(HTTParty::Response, success?: true, body: '{"success":true}')
      end

      expect(described_class.new.create_worker_route('www.sunshine-rv.com')).to be true
    end

    it 'treats an existing route as success' do
      ENV['CLOUDFLARE_WORKER_SCRIPT'] = 'tenant-host-proxy'
      allow(described_class).to receive(:post).and_return(
        instance_double(HTTParty::Response, success?: false,
                                            body: '{"errors":[{"message":"route already exists"}]}')
      )

      expect(described_class.new.create_worker_route('www.sunshine-rv.com')).to be true
    end

    # Routes pointing at a script that does not exist would fail every request, so doing
    # nothing is correct until the Worker is deployed.
    it 'does nothing when no Worker script is configured' do
      ENV.delete('CLOUDFLARE_WORKER_SCRIPT')
      allow(Rails.application.credentials).to receive(:dig).and_return(nil)
      expect(described_class).not_to receive(:post)

      expect(described_class.new.create_worker_route('www.sunshine-rv.com')).to be false
    end
  end

  describe '#add_custom_hostname' do
    before { configure! }

    let(:success) { instance_double(HTTParty::Response, success?: true, body: '{}', parsed_response: { 'success' => true, 'result' => {} }) }

    it 'posts to the custom_hostnames endpoint with the fallback origin' do
      expect(described_class).to receive(:post) do |path, opts|
        expect(path).to eq('/zones/zone123/custom_hostnames')
        expect(JSON.parse(opts[:body])).to include(
          'hostname' => 'www.sunshine-rv.com',
          'custom_origin_server' => 'origin.mydealertide.com'
        )
        success
      end
      allow_any_instance_of(described_class).to receive(:handle_response).and_return({})

      described_class.new.add_custom_hostname('www.sunshine-rv.com')
    end

    it 'retries without custom_origin_server when the plan rejects it' do
      rejected = instance_double(HTTParty::Response, success?: false,
                                                     body: '{"errors":[{"message":"custom_origin_server is not available"}]}')
      bodies = []
      allow(described_class).to receive(:post) do |_path, opts|
        bodies << JSON.parse(opts[:body])
        bodies.length == 1 ? rejected : success
      end
      allow_any_instance_of(described_class).to receive(:handle_response).and_return({})

      described_class.new.add_custom_hostname('www.sunshine-rv.com')

      expect(bodies.length).to eq(2)
      expect(bodies.first).to have_key('custom_origin_server')
      expect(bodies.last).not_to have_key('custom_origin_server')
    end

    # Cloudflare holds a hostname whenever a previous attempt provisioned and then failed on
    # our side. That stranded the tenant permanently: the hostname was unusable here,
    # invisible to them, and no amount of retrying cleared it.
    it 'adopts a hostname Cloudflare already holds' do
      duplicate = instance_double(HTTParty::Response, success?: false,
                                                      body: '{"errors":[{"code":1406,"message":"Duplicate custom hostname found."}]}')
      allow(described_class).to receive(:post).and_return(duplicate)
      allow_any_instance_of(described_class).to receive(:list_custom_hostnames).and_return(
        [{ hostname: 'other.example', id: 'cf-other' },
         { hostname: 'www.sunshine-rv.com', id: 'cf-existing' }]
      )

      result = described_class.new.add_custom_hostname('www.sunshine-rv.com')

      expect(result[:result][:id]).to eq('cf-existing')
    end

    it 'matches the existing hostname case-insensitively' do
      duplicate = instance_double(HTTParty::Response, success?: false,
                                                      body: '{"errors":[{"message":"Duplicate custom hostname found."}]}')
      allow(described_class).to receive(:post).and_return(duplicate)
      allow_any_instance_of(described_class).to receive(:list_custom_hostnames).and_return(
        [{ hostname: 'WWW.Sunshine-RV.com', id: 'cf-existing' }]
      )

      expect(described_class.new.add_custom_hostname('www.sunshine-rv.com')[:result][:id])
        .to eq('cf-existing')
    end

    it 'raises when Cloudflare reports a duplicate it cannot produce' do
      duplicate = instance_double(HTTParty::Response, success?: false,
                                                      body: '{"errors":[{"message":"Duplicate custom hostname found."}]}')
      allow(described_class).to receive(:post).and_return(duplicate)
      allow_any_instance_of(described_class).to receive(:list_custom_hostnames).and_return([])

      expect { described_class.new.add_custom_hostname('www.sunshine-rv.com') }
        .to raise_error(described_class::CloudflareError, /was not found/)
    end

    it 'does not retry on an unrelated failure' do
      other = instance_double(HTTParty::Response, success?: false, body: '{"errors":[{"message":"zone not found"}]}')
      allow(described_class).to receive(:post).and_return(other)
      allow_any_instance_of(described_class).to receive(:handle_response).and_return({})

      described_class.new.add_custom_hostname('www.sunshine-rv.com')

      expect(described_class).to have_received(:post).once
    end
  end
end
