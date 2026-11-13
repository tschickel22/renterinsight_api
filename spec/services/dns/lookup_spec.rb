# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Dns::Lookup do
  # The bug this guards against: Resolv::DNS.open(timeouts: 3) treats its argument as
  # nameserver configuration, not a timeout, and returns a resolver that answers nothing
  # without ever raising. It silently disabled registrar detection, Domain Connect
  # discovery, the MAIL FROM collision check and DNS verification at once. Every spec
  # stubbed Resolv::DNS, so nothing exercised the call signature itself.
  it 'opens the resolver with no arguments, since anything passed is nameserver config' do
    dns = instance_double(Resolv::DNS)
    allow(dns).to receive(:timeouts=)
    allow(dns).to receive(:getresources).and_return([])

    expect(Resolv::DNS).to receive(:open).with(no_args).and_yield(dns)

    described_class.txt('example.com')
  end

  it 'sets the timeout on the resolver rather than passing it to open' do
    dns = instance_double(Resolv::DNS)
    allow(Resolv::DNS).to receive(:open).and_yield(dns)
    allow(dns).to receive(:getresources).and_return([])

    expect(dns).to receive(:timeouts=).with(7)

    described_class.txt('example.com', timeout: 7)
  end

  describe 'record extraction' do
    def stub_records(records)
      dns = instance_double(Resolv::DNS)
      allow(Resolv::DNS).to receive(:open).and_yield(dns)
      allow(dns).to receive(:timeouts=)
      allow(dns).to receive(:getresources).and_return(records)
    end

    it 'joins split TXT strings, which is how long records arrive' do
      stub_records([instance_double(Resolv::DNS::Resource::IN::TXT, strings: %w[part-one part-two])])

      expect(described_class.txt('example.com')).to eq(['part-onepart-two'])
    end

    it 'returns MX exchanges rather than the record name' do
      stub_records([instance_double(Resolv::DNS::Resource::IN::MX, exchange: 'mail.example.com')])

      expect(described_class.mx('example.com')).to eq(['mail.example.com'])
    end

    it 'lowercases nameservers so suffix matching is reliable' do
      stub_records([instance_double(Resolv::DNS::Resource::IN::NS, name: 'NS57.DomainControl.com')])

      expect(described_class.ns('example.com')).to eq(['ns57.domaincontrol.com'])
    end

    # Resolv has no CAA class, so the raw RDATA is parsed here: flags, tag length, tag, value.
    it 'parses CAA from raw RDATA' do
      stub_records([described_class::CAA.new("\x00\x05issuessl.com")])

      expect(described_class.caa('example.com')).to eq([{ flags: 0, tag: 'issue', value: 'ssl.com' }])
    end
  end

  it 'asks a specific name server when one is given' do
    dns = instance_double(Resolv::DNS)
    allow(dns).to receive(:timeouts=)
    allow(dns).to receive(:getresources).and_return([])

    expect(Resolv::DNS).to receive(:open).with({ nameserver: ['1.2.3.4'] }).and_yield(dns)

    described_class.resolve('example.com', Resolv::DNS::Resource::IN::A, nameserver: '1.2.3.4', &:ttl)
  end

  describe 'failure handling' do
    before { allow(Resolv::DNS).to receive(:open).and_raise(Resolv::ResolvError) }

    it 'returns empty from the forgiving wrapper' do
      expect(described_class.txt('example.com')).to eq([])
    end

    # A collision check must be able to tell "no records" from "could not ask". Treating an
    # unanswered query as a free name is how a tenant's MX gets overwritten.
    it 'raises from resolve! so callers can distinguish it' do
      expect { described_class.resolve!('example.com', Resolv::DNS::Resource::IN::MX) { |r| r } }
        .to raise_error(Resolv::ResolvError)
    end
  end

  it 'returns empty for a blank name without a lookup' do
    expect(Resolv::DNS).not_to receive(:open)

    expect(described_class.txt('')).to eq([])
  end

  # www.cbhms.com, 2026-11-13: the CNAME had been fixed at GoDaddy and every public
  # resolver had it, but Check DNS kept reading the container's cached old value for up to
  # an hour. With a zone, the record is asked of that zone's own name server.
  describe 'fresh answers from the zone\'s own name server' do
    let(:cname_type) { Resolv::DNS::Resource::IN::CNAME }

    before do
      allow(described_class).to receive(:ns).with('cbhms.com', timeout: 3).and_return(['ns35.domaincontrol.com'])
      allow(described_class).to receive(:a).with('ns35.domaincontrol.com', timeout: 3).and_return(['97.74.100.18'])
    end

    it 'asks the authoritative server when given a zone' do
      expect(described_class).to receive(:resolve!)
        .with('www.cbhms.com', cname_type, timeout: 3, nameserver: '97.74.100.18')
        .and_return(['origin.mydealertide.com'])
      expect(described_class).not_to receive(:resolve)

      expect(described_class.cname('www.cbhms.com', zone: 'cbhms.com')).to eq(['origin.mydealertide.com'])
    end

    it 'falls back to the ordinary lookup when the authoritative server has nothing' do
      allow(described_class).to receive(:resolve!).with('www.cbhms.com', cname_type, timeout: 3, nameserver: '97.74.100.18').and_return([])
      expect(described_class).to receive(:resolve).with('www.cbhms.com', cname_type, timeout: 3).and_return(['cbhms.com'])

      expect(described_class.cname('www.cbhms.com', zone: 'cbhms.com')).to eq(['cbhms.com'])
    end

    it 'falls back when the authoritative server cannot be reached' do
      allow(described_class).to receive(:resolve!).with('www.cbhms.com', cname_type, timeout: 3, nameserver: '97.74.100.18').and_raise(Resolv::ResolvError)
      expect(described_class).to receive(:resolve).with('www.cbhms.com', cname_type, timeout: 3).and_return(['origin.mydealertide.com'])

      expect(described_class.cname('www.cbhms.com', zone: 'cbhms.com')).to eq(['origin.mydealertide.com'])
    end

    it 'uses the ordinary lookup without a zone' do
      expect(described_class).not_to receive(:ns)
      expect(described_class).to receive(:resolve).with('www.cbhms.com', cname_type, timeout: 3).and_return([])

      described_class.cname('www.cbhms.com')
    end
  end
end
