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
end
