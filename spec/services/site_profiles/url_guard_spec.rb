# frozen_string_literal: true

require 'rails_helper'

RSpec.describe SiteProfiles::UrlGuard do
  def allow_dns(host, *addresses)
    allow(Addrinfo).to receive(:getaddrinfo)
      .with(host, nil, nil, :STREAM)
      .and_return(addresses.map { |a| Addrinfo.ip(a) })
  end

  describe '.validate!' do
    it 'accepts a public https URL' do
      allow_dns('example.com', '93.184.216.34')
      uri, addresses = described_class.validate!('https://example.com/about')
      expect(uri.host).to eq('example.com')
      expect(addresses.first.to_s).to eq('93.184.216.34')
    end

    it 'rejects non-http schemes' do
      %w[file:///etc/passwd ftp://example.com gopher://example.com javascript:alert(1)].each do |url|
        expect { described_class.validate!(url) }
          .to raise_error(described_class::BlockedUrlError, /only http and https/i)
      end
    end

    it 'rejects the cloud metadata endpoint' do
      expect { described_class.validate!('http://169.254.169.254/latest/meta-data/') }
        .to raise_error(described_class::BlockedUrlError, /non-public address/i)
    end

    it 'rejects loopback in every spelling' do
      allow_dns('localhost', '127.0.0.1')
      [
        'http://127.0.0.1:3001/api/v1/websites',
        'http://localhost:3001/',
        'http://[::1]:3001/'
      ].each do |url|
        expect { described_class.validate!(url) }
          .to raise_error(described_class::BlockedUrlError)
      end
    end

    it 'rejects RFC1918 space' do
      ['http://10.0.0.5/', 'http://172.16.4.4/', 'http://192.168.1.1/'].each do |url|
        expect { described_class.validate!(url) }
          .to raise_error(described_class::BlockedUrlError, /non-public address/i)
      end
    end

    it 'rejects a public hostname that resolves to a private address' do
      # The DNS-rebinding shape: the name looks fine, the answer does not.
      allow_dns('sneaky.example.com', '10.1.2.3')
      expect { described_class.validate!('https://sneaky.example.com/') }
        .to raise_error(described_class::BlockedUrlError, /non-public address/i)
    end

    it 'rejects when any resolved address is private, not just the first' do
      allow_dns('mixed.example.com', '93.184.216.34', '192.168.0.9')
      expect { described_class.validate!('https://mixed.example.com/') }
        .to raise_error(described_class::BlockedUrlError)
    end

    it 'does not leak the resolved internal address in the error' do
      allow_dns('sneaky.example.com', '10.1.2.3')
      described_class.validate!('https://sneaky.example.com/')
    rescue described_class::BlockedUrlError => e
      expect(e.message).not_to include('10.1.2.3')
    end

    it 'rejects a hostname that does not resolve' do
      allow(Addrinfo).to receive(:getaddrinfo).and_raise(SocketError)
      expect { described_class.validate!('https://nope.invalid/') }
        .to raise_error(described_class::BlockedUrlError, /could not resolve/i)
    end

    it 'rejects a URL with no host' do
      expect { described_class.validate!('https://') }
        .to raise_error(described_class::BlockedUrlError)
    end
  end

  describe '.blocked?' do
    it 'classifies addresses' do
      expect(described_class.blocked?('93.184.216.34')).to be(false)
      expect(described_class.blocked?('8.8.8.8')).to be(false)
      expect(described_class.blocked?('127.0.0.1')).to be(true)
      expect(described_class.blocked?('169.254.169.254')).to be(true)
      expect(described_class.blocked?('10.0.0.1')).to be(true)
      expect(described_class.blocked?('::1')).to be(true)
      expect(described_class.blocked?('fc00::1')).to be(true)
      expect(described_class.blocked?('not-an-ip')).to be(true)
    end
  end
end
