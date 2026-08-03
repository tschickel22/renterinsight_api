# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Dns::Registrar do
  def stub_nameservers(*names)
    allow(Dns::Lookup).to receive(:ns).and_return(names.map(&:downcase))
  end

  before { Rails.cache.clear }

  # NS records live at the zone apex, so asking about www.dealer.com returns nothing and
  # every www hostname silently fell back to generic instructions — which is most dealer
  # website domains, since apex hostnames cannot be used at all.
  it 'walks up to the zone when the hostname itself has no NS records' do
    allow(Dns::Lookup).to receive(:ns).with('www.dealer.example', anything).and_return([])
    allow(Dns::Lookup).to receive(:ns).with('dealer.example', anything)
                                      .and_return(['ns57.domaincontrol.com'])

    expect(described_class.for('www.dealer.example')[:key]).to eq('godaddy')
  end

  it 'gives up rather than querying past the registrable domain' do
    allow(Dns::Lookup).to receive(:ns).and_return([])

    expect(described_class.for('shop.www.dealer.example')[:key]).to be_nil
    expect(Dns::Lookup).to have_received(:ns).exactly(3).times
  end

  it 'detects GoDaddy from its nameservers' do
    stub_nameservers('ns57.domaincontrol.com', 'ns58.domaincontrol.com')

    result = described_class.for('tomshotsauce.com')

    expect(result[:key]).to eq('godaddy')
    expect(result[:name]).to eq('GoDaddy')
    expect(result[:steps]).to be_present
  end

  it 'detects Cloudflare and warns about proxied records' do
    stub_nameservers('kate.ns.cloudflare.com', 'rick.ns.cloudflare.com')

    result = described_class.for('dealer.example')

    expect(result[:key]).to eq('cloudflare')
    # An orange-clouded CNAME resolves to Cloudflare rather than amazonses.com, so DKIM can
    # never verify. This is the most common Cloudflare failure and has to be called out.
    expect(result[:warning]).to match(/DNS only|grey cloud/i)
  end

  it 'detects Route 53 from a partial suffix match' do
    stub_nameservers('ns-123.awsdns-45.org', 'ns-678.awsdns-90.co.uk')

    expect(described_class.for('dealer.example')[:key]).to eq('route53')
  end

  it 'detects Namecheap' do
    stub_nameservers('dns1.registrar-servers.com')

    expect(described_class.for('dealer.example')[:key]).to eq('namecheap')
  end

  it 'falls back to generic instructions for an unknown provider' do
    stub_nameservers('ns1.some-tiny-host.example')

    result = described_class.for('dealer.example')

    expect(result[:key]).to be_nil
    expect(result[:steps]).to be_present
    expect(result[:field_label]).to eq('Host')
  end

  it 'falls back to generic when the NS lookup fails' do
    allow(Dns::Lookup).to receive(:ns).and_return([])

    expect(described_class.for('dealer.example')[:key]).to be_nil
  end

  it 'returns generic for a blank hostname without a lookup' do
    expect(Dns::Lookup).not_to receive(:ns)

    expect(described_class.for('')[:key]).to be_nil
  end

  it 'shows a relative example host, since that is what breaks verification' do
    stub_nameservers('ns57.domaincontrol.com')

    expect(described_class.for('tomshotsauce.com')[:example_host]).to eq('token._domainkey')
  end

  it 'caches the lookup so it does not run on every page view' do
    # The test environment uses a null store, so this example needs a real one to prove the
    # caching rather than silently passing through it.
    original = Rails.cache
    Rails.cache = ActiveSupport::Cache::MemoryStore.new
    stub_nameservers('ns57.domaincontrol.com')

    described_class.for('tomshotsauce.com')
    described_class.for('tomshotsauce.com')

    expect(Dns::Lookup).to have_received(:ns).once
  ensure
    Rails.cache = original
  end
end
