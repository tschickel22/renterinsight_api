# frozen_string_literal: true

require 'rails_helper'

RSpec.describe RefreshWebsiteDomainStatusJob do
  let(:company) { Company.create!(name: "Co-#{SecureRandom.hex(3)}") }

  def domain_with(attrs = {})
    company.company_domains.create!(
      { hostname: "d-#{SecureRandom.hex(4)}.example.com", web_enabled: true,
        cloudflare_custom_hostname_id: "cf-#{SecureRandom.hex(4)}" }.merge(attrs)
    )
  end

  def expect_refreshed(domains)
    refreshed = []
    allow(Websites::CloudflareStatusRefresher).to receive(:call) do |domain|
      refreshed << domain.id
      Websites::CloudflareStatusRefresher::Result.new(updated: true, verified: false, ssl_active: false)
    end
    described_class.new.perform
    expect(refreshed).to match_array(domains.map(&:id))
  end

  it 'refreshes a domain that has never been checked' do
    pending_domain = domain_with(dns_checked_at: nil, verification_status: 'pending')

    expect_refreshed([pending_domain])
  end

  it 'refreshes a domain that is verified but still waiting on its certificate' do
    waiting = domain_with(verification_status: 'active', ssl_status: 'pending_validation', dns_checked_at: nil)

    expect_refreshed([waiting])
  end

  # A finished domain re-polled forever would spend an API call per domain per sweep for no
  # information.
  it 'leaves a fully active domain alone' do
    domain_with(verification_status: 'active', ssl_status: 'active', dns_checked_at: nil)

    expect_refreshed([])
  end

  it 'skips a domain with no Cloudflare hostname' do
    domain_with(cloudflare_custom_hostname_id: nil, dns_checked_at: nil)

    expect_refreshed([])
  end

  it 'skips an email-only domain' do
    domain_with(web_enabled: false, dns_checked_at: nil)

    expect_refreshed([])
  end

  it 'skips a domain checked within the recheck interval' do
    domain_with(dns_checked_at: 1.minute.ago)

    expect_refreshed([])
  end

  it 'gives up on a domain older than the cutoff' do
    stale = domain_with(dns_checked_at: nil)
    stale.update_column(:created_at, 8.days.ago)

    expect_refreshed([])
  end

  it 'keeps sweeping after one domain fails' do
    failing = domain_with(dns_checked_at: nil)
    healthy = domain_with(dns_checked_at: nil)

    allow(Websites::CloudflareStatusRefresher).to receive(:call) do |domain|
      raise 'boom' if domain.id == failing.id

      Websites::CloudflareStatusRefresher::Result.new(updated: true, verified: true, ssl_active: true)
    end

    expect { described_class.new.perform }.not_to raise_error
    expect(Websites::CloudflareStatusRefresher).to have_received(:call).exactly(2).times
    expect(healthy.reload).to be_present
  end
end
