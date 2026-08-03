# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Websites::HostResolver do
  let(:company) { Company.create!(name: "Co-#{SecureRandom.hex(3)}") }
  let(:location) { company.locations.create!(name: 'Showroom') }

  def website(attrs = {})
    Website.create!({ company_id: company.id, location_id: location.id, name: 'Dealer Site',
                      slug: "s-#{SecureRandom.hex(4)}", status: 'published' }.merge(attrs))
  end

  def domain_for(site, hostname, verified: true)
    company.company_domains.create!(
      hostname: hostname, website_id: site&.id,
      verification_status: verified ? 'active' : 'pending'
    )
  end

  describe 'a dealer custom domain' do
    it 'resolves through the linked CompanyDomain' do
      site = website
      domain_for(site, 'sunshine-rv.com')

      result = described_class.call('sunshine-rv.com')

      expect(result.website).to eq(site)
      expect(result.canonical_host).to eq('sunshine-rv.com')
    end

    it 'matches the exact host before the other www spelling' do
      bare = website
      wwwed = website
      domain_for(bare, 'sunshine-rv.com')
      domain_for(wwwed, 'www.sunshine-rv.com')

      expect(described_class.call('www.sunshine-rv.com').website).to eq(wwwed)
      expect(described_class.call('sunshine-rv.com').website).to eq(bare)
    end

    it 'falls back to the other www spelling when only one is registered' do
      site = website
      domain_for(site, 'sunshine-rv.com')

      expect(described_class.call('www.sunshine-rv.com').website).to eq(site)
    end

    it 'ignores a domain that is not linked to a website' do
      domain_for(nil, 'unlinked.com')

      expect(described_class.call('unlinked.com')).to be_nil
    end

    it 'ignores a port suffix' do
      site = website
      domain_for(site, 'sunshine-rv.com')

      expect(described_class.call('sunshine-rv.com:3001').website).to eq(site)
    end
  end

  describe 'publication state' do
    it 'refuses to serve a draft site on a live domain' do
      site = website(status: 'draft')
      domain_for(site, 'sunshine-rv.com')

      expect(described_class.call('sunshine-rv.com')).to be_nil
    end

    it 'refuses to serve a deleted site' do
      site = website(is_deleted: true)
      domain_for(site, 'sunshine-rv.com')

      expect(described_class.call('sunshine-rv.com')).to be_nil
    end
  end

  describe 'tenant isolation' do
    it 'will not serve a website belonging to another company' do
      other = Company.create!(name: "Other-#{SecureRandom.hex(3)}")
      foreign = Website.create!(company_id: other.id, location_id: other.locations.create!(name: 'L').id,
                                name: 'Other', slug: "o-#{SecureRandom.hex(4)}", status: 'published')
      # A domain on our company pointed at someone else's website id.
      company.company_domains.create!(hostname: 'sneaky.com', website_id: foreign.id,
                                      verification_status: 'active')

      expect(described_class.call('sneaky.com')).to be_nil
    end
  end

  describe 'fallbacks' do
    it 'resolves a legacy websites.domain assignment' do
      site = website(domain: 'legacy-dealer.com')

      expect(described_class.call('legacy-dealer.com').website).to eq(site)
    end

    it 'resolves a platform subdomain' do
      site = website(subdomain: 'summit-park')
      root = Brand.current.subdomain_root

      expect(described_class.call("summit-park.#{root}").website).to eq(site)
    end

    it 'returns nil for an unknown host' do
      expect(described_class.call('nobody.example')).to be_nil
    end

    it 'returns nil for a blank host' do
      expect(described_class.call('')).to be_nil
      expect(described_class.call(nil)).to be_nil
    end
  end
end
