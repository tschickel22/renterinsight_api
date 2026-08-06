# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Marketing::MarketingSiteProvisioner do
  # Company creation seeds its own Corporate location, and a unique index
  # enforces one per company — so nothing to create here.
  let(:company) { Company.create!(name: "Prov-#{SecureRandom.hex(4)}") }

  it 'creates a marketing container for a company that has none' do
    site = described_class.call(company: company)

    expect(site).to be_persisted
    expect(site.kind).to eq('marketing')
    expect(site.marketing_container?).to be(true)
    expect(site.company_id).to eq(company.id)
  end

  it 'is idempotent — a second call returns the same container' do
    first = described_class.call(company: company)
    second = described_class.call(company: company)

    expect(second.id).to eq(first.id)
    expect(Website.marketing_containers.where(company_id: company.id).count).to eq(1)
  end

  # Websites::HostResolver#published_scope only resolves sites with status
  # 'published'. The container is invisible, so nobody would ever publish it by
  # hand — a draft container would make every landing page unreachable with no
  # visible cause.
  it 'creates the container already published so host resolution can reach it' do
    site = described_class.call(company: company)

    expect(site.status).to eq('published')
    expect(site.published_at).to be_present
    expect(Website.where(is_deleted: [false, nil], status: 'published')).to include(site)
  end

  it 'is excluded from the .sites scope that user-facing reads use' do
    site = described_class.call(company: company)

    expect(company.websites.sites).not_to include(site)
    expect(company.websites.marketing_containers).to include(site)
  end

  it 'gives the container a globally unique subdomain' do
    other = Company.create!(name: company.name)

    first = described_class.call(company: company)
    second = described_class.call(company: other)

    expect(second.subdomain).to be_present
    expect(second.subdomain).not_to eq(first.subdomain)
  end

  it 'raises a clear error when the company has no active location' do
    bare = Company.create!(name: "Bare-#{SecureRandom.hex(4)}")
    bare.locations.update_all(active: false)

    expect { described_class.call(company: bare) }
      .to raise_error(described_class::ProvisioningError, /no active location/)
  end
end
