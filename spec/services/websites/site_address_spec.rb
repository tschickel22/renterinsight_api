# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Websites::SiteAddress do
  let(:website) { instance_double(Website, subdomain: 'mhmasters') }

  def with_suffix(value)
    original = ENV['PLATFORM_SITE_LABEL_SUFFIX']
    ENV['PLATFORM_SITE_LABEL_SUFFIX'] = value
    yield
  ensure
    ENV['PLATFORM_SITE_LABEL_SUFFIX'] = original
  end

  before { allow(Brand).to receive(:current).and_return(double(site_host_root: 'mydealertide.com', subdomain_root: 'mydealertide.com')) }

  # Production is the case that must not move. Every method is an identity
  # function when no suffix is set.
  context 'with no suffix configured' do
    it 'builds the host it always built' do
      expect(described_class.host_for(website)).to eq('mhmasters.mydealertide.com')
    end

    it 'reads a label back unchanged' do
      expect(described_class.subdomain_from_label('mhmasters')).to eq('mhmasters')
    end

    it 'treats an empty suffix the same as an unset one' do
      with_suffix('') do
        expect(described_class.host_for(website)).to eq('mhmasters.mydealertide.com')
        expect(described_class.subdomain_from_label('mhmasters')).to eq('mhmasters')
      end
    end
  end

  context 'with a suffix configured' do
    it 'marks the host so it cannot collide with the production one' do
      with_suffix('-staging') do
        expect(described_class.host_for(website)).to eq('mhmasters-staging.mydealertide.com')
      end
    end

    it 'reads its own label back to the stored subdomain' do
      with_suffix('-staging') do
        expect(described_class.subdomain_from_label('mhmasters-staging')).to eq('mhmasters')
      end
    end

    # The reason the suffix is checked rather than merely stripped: an
    # environment that requires a marker must not answer for a host without one.
    it 'refuses a label belonging to another environment' do
      with_suffix('-staging') do
        expect(described_class.subdomain_from_label('mhmasters')).to be_nil
      end
    end

    it 'refuses a label that is nothing but the suffix' do
      with_suffix('-staging') do
        expect(described_class.subdomain_from_label('-staging')).to be_nil
      end
    end
  end

  describe 'missing pieces' do
    it 'has no host without a subdomain' do
      expect(described_class.host_for(instance_double(Website, subdomain: nil))).to be_nil
      expect(described_class.host_for(nil)).to be_nil
    end

    it 'has no host without a configured root' do
      allow(Brand).to receive(:current).and_return(double(site_host_root: nil, subdomain_root: nil))

      expect(described_class.host_for(website)).to be_nil
    end
  end

  describe 'HostResolver integration' do
    let(:company) { Company.create!(name: "Co-#{SecureRandom.hex(3)}") }
    let(:location) { company.locations.create!(name: 'Showroom') }

    let!(:site) do
      Website.create!(company_id: company.id, location_id: location.id, name: 'MH Masters',
                      slug: "s-#{SecureRandom.hex(4)}", subdomain: 'mhmasters',
                      status: 'published', published_at: Time.current)
    end

    it 'resolves the production host when no suffix is set' do
      result = Websites::HostResolver.new('mhmasters.mydealertide.com').call

      expect(result&.website).to eq(site)
    end

    # The bug this whole change exists for: a staging publish claimed the
    # production hostname, and production had no such site to serve.
    it 'resolves only its own marked host when a suffix is set' do
      with_suffix('-staging') do
        expect(Websites::HostResolver.new('mhmasters-staging.mydealertide.com').call&.website).to eq(site)
        expect(Websites::HostResolver.new('mhmasters.mydealertide.com').call).to be_nil
      end
    end
  end

  describe 'Website#public_url' do
    let(:company) { Company.create!(name: "Co-#{SecureRandom.hex(3)}") }
    let(:location) { company.locations.create!(name: 'Showroom') }

    # Distinct subdomains per site: uniqueness is global, so reusing one inside
    # a single example fails on the validation rather than on what is asserted.
    def site(status:, subdomain: :auto)
      subdomain = "mh-#{SecureRandom.hex(4)}" if subdomain == :auto
      Website.create!(company_id: company.id, location_id: location.id, name: 'MH Masters',
                      slug: "s-#{SecureRandom.hex(4)}", subdomain: subdomain,
                      status: status, published_at: (status == 'published' ? Time.current : nil))
    end

    it 'names the address a visitor can reach' do
      expect(site(status: 'published', subdomain: 'mhmasters').public_url)
        .to eq('https://mhmasters.mydealertide.com')
    end

    it 'carries the environment marker' do
      with_suffix('-staging') do
        expect(site(status: 'published', subdomain: 'mhmasters').public_url)
          .to eq('https://mhmasters-staging.mydealertide.com')
      end
    end

    # Nil rather than a URL, so the builder falls back to the in-app preview
    # route instead of offering an address that answers with nothing.
    it 'has no address for a site the resolver would refuse' do
      expect(site(status: 'draft').public_url).to be_nil
      expect(site(status: 'unpublished').public_url).to be_nil
      expect(site(status: 'published', subdomain: nil).public_url).to be_nil
    end
  end

  describe 'SubdomainRouteProvisioner' do
    it 'binds the route to the marked host' do
      with_suffix('-staging') do
        expect(Websites::SubdomainRouteProvisioner.host_for(website))
          .to eq('mhmasters-staging.mydealertide.com')
      end
    end
  end
end
