# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Websites::SubdomainRouteProvisioner do
  let(:company) { Company.create!(name: "Co-#{SecureRandom.hex(3)}") }
  let(:location) { company.locations.create!(name: 'Showroom') }

  def site(attrs = {})
    Website.create!({ company_id: company.id, location_id: location.id, name: 'Dealer Site',
                      slug: "s-#{SecureRandom.hex(4)}", status: 'published' }.merge(attrs))
  end

  describe '.host_for' do
    it 'builds the host from the site host root, not the platform domain' do
      expect(described_class.host_for(site(subdomain: 'summit-park')))
        .to eq("summit-park.#{Brand.current.site_host_root}")
    end

    it 'is nil without a subdomain, since there is nothing to bind' do
      expect(described_class.host_for(site)).to be_nil
      expect(described_class.host_for(nil)).to be_nil
    end
  end

  describe '.ensure' do
    let(:cloudflare) { instance_double(CloudflareSaasService) }

    before { allow(CloudflareSaasService).to receive(:configured?).and_return(true) }

    it 'binds the Worker to the site host' do
      allow(CloudflareSaasService).to receive(:new).and_return(cloudflare)
      expect(cloudflare).to receive(:create_worker_route)
        .with("summit-park.#{Brand.current.site_host_root}").and_return(true)

      expect(described_class.ensure(site(subdomain: 'summit-park'))).to be(true)
    end

    it 'does nothing for a site with no subdomain' do
      expect(CloudflareSaasService).not_to receive(:new)

      expect(described_class.ensure(site)).to be(false)
    end

    # Development and test have no Cloudflare credentials, and the script is
    # deliberately unset before the Worker exists. Neither is an error.
    it 'is a no-op when Cloudflare is not configured' do
      allow(CloudflareSaasService).to receive(:configured?).and_return(false)

      expect(described_class.ensure(site(subdomain: 'summit-park'))).to be(false)
    end

    # A site whose route failed is still a valid site.
    it 'swallows a Cloudflare failure rather than raising at the caller' do
      allow(CloudflareSaasService).to receive(:new).and_raise(StandardError, 'boom')

      expect { described_class.ensure(site(subdomain: 'summit-park')) }.not_to raise_error
    end
  end

  describe '.remove' do
    let(:cloudflare) { instance_double(CloudflareSaasService) }

    before do
      allow(CloudflareSaasService).to receive(:configured?).and_return(true)
      allow(CloudflareSaasService).to receive(:new).and_return(cloudflare)
    end

    it 'unbinds the given host' do
      expect(cloudflare).to receive(:delete_worker_route).with('old.mydealertide.com').and_return(true)

      expect(described_class.remove('old.mydealertide.com')).to be(true)
    end

    it 'ignores a blank host' do
      expect(CloudflareSaasService).not_to receive(:new)

      expect(described_class.remove(nil)).to be(false)
      expect(described_class.remove('')).to be(false)
    end
  end

  describe 'Website callback' do
    it 'enqueues on subdomain assignment' do
      expect { site(subdomain: 'summit-park') }
        .to have_enqueued_job(WebsiteSubdomainRouteJob)
    end

    it 'does not enqueue for a site with no subdomain' do
      expect { site }.not_to have_enqueued_job(WebsiteSubdomainRouteJob)
    end

    # A theme tweak must not spend a Cloudflare call.
    it 'does not enqueue when something unrelated changes' do
      page = site(subdomain: 'summit-park')

      expect { page.update!(name: 'Renamed') }.not_to have_enqueued_job(WebsiteSubdomainRouteJob)
    end

    # A rename has to unbind the old host, or it keeps answering.
    it 'passes the previous host when the subdomain changes' do
      page = site(subdomain: 'summit-park')
      root = Brand.current.site_host_root

      expect { page.update!(subdomain: 'summit-park-2') }
        .to have_enqueued_job(WebsiteSubdomainRouteJob).with(page.id, "summit-park.#{root}")
    end

    it 'enqueues on soft delete so the subdomain stops answering' do
      page = site(subdomain: 'summit-park')

      expect { page.update!(is_deleted: true) }
        .to have_enqueued_job(WebsiteSubdomainRouteJob)
    end
  end

  describe WebsiteSubdomainRouteJob do
    # described_class rebinds to the job inside this block, so the provisioner
    # is named in full.
    let(:provisioner) { Websites::SubdomainRouteProvisioner }

    it 'unbinds the old host before binding the new one' do
      page = site(subdomain: 'summit-park')

      expect(provisioner).to receive(:remove).with('old.mydealertide.com').ordered
      expect(provisioner).to receive(:ensure).with(page).ordered

      described_class.perform_now(page.id, 'old.mydealertide.com')
    end

    it 'does not rebind a soft-deleted site' do
      page = site(subdomain: 'summit-park')
      page.update_column(:is_deleted, true)

      expect(provisioner).to receive(:remove).with('old.mydealertide.com')
      expect(provisioner).not_to receive(:ensure)

      described_class.perform_now(page.id, 'old.mydealertide.com')
    end

    it 'tolerates a website that no longer exists' do
      expect { WebsiteSubdomainRouteJob.perform_now(-1, nil) }.not_to raise_error
    end
  end
end
