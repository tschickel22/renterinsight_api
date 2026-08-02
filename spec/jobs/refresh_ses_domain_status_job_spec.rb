# frozen_string_literal: true

require 'rails_helper'

RSpec.describe RefreshSesDomainStatusJob do
  let(:company) { Company.create!(name: "Co-#{SecureRandom.hex(3)}") }

  def domain_with(attrs = {})
    company.company_domains.create!(
      { hostname: "d-#{SecureRandom.hex(4)}.example.com", email_enabled: true }.merge(attrs)
    )
  end

  def expect_refreshed(domains)
    refreshed = []
    allow(Ses::IdentityManager).to receive(:new) do |domain|
      refreshed << domain.id
      instance_double(Ses::IdentityManager, refresh_status!: domain)
    end
    described_class.new.perform
    expect(refreshed).to match_array(domains.map(&:id))
  end

  it 'refreshes a pending domain that has never been checked' do
    pending_domain = domain_with(ses_checked_at: nil)

    expect_refreshed([pending_domain])
  end

  it 'skips a domain already verified' do
    domain_with(email_verified_at: Time.current, ses_checked_at: nil)

    expect_refreshed([])
  end

  it 'skips a domain with email sending disabled' do
    domain_with(email_enabled: false, ses_checked_at: nil)

    expect_refreshed([])
  end

  it 'skips a domain checked within the recheck interval' do
    domain_with(ses_checked_at: 1.minute.ago)

    expect_refreshed([])
  end

  it 'gives up on a domain older than the cutoff' do
    stale = domain_with(ses_checked_at: nil)
    stale.update_column(:created_at, 8.days.ago)

    expect_refreshed([])
  end

  it 'keeps sweeping after one domain fails' do
    failing = domain_with(ses_checked_at: nil)
    healthy = domain_with(ses_checked_at: nil)

    allow(Ses::IdentityManager).to receive(:new) do |domain|
      if domain.id == failing.id
        instance_double(Ses::IdentityManager).tap do |m|
          allow(m).to receive(:refresh_status!).and_raise(Ses::IdentityManager::SesError, 'boom')
        end
      else
        instance_double(Ses::IdentityManager, refresh_status!: domain)
      end
    end

    expect { described_class.new.perform }.not_to raise_error
    expect(Ses::IdentityManager).to have_received(:new).exactly(2).times
    expect(healthy.reload).to be_present
  end

  it 'refreshes a single domain when given an id' do
    target = domain_with(ses_checked_at: 1.minute.ago)
    manager = instance_double(Ses::IdentityManager, refresh_status!: target)
    allow(Ses::IdentityManager).to receive(:new).with(target).and_return(manager)

    described_class.new.perform(target.id)

    expect(manager).to have_received(:refresh_status!)
  end
end
