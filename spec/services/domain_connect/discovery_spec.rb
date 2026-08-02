# frozen_string_literal: true

require 'rails_helper'

RSpec.describe DomainConnect::Discovery do
  let(:dns) { instance_double(Resolv::DNS) }

  def stub_txt(value)
    allow(Resolv::DNS).to receive(:open).and_yield(dns)
    records = Array(value).map { |v| instance_double(Resolv::DNS::Resource::IN::TXT, strings: [v]) }
    allow(dns).to receive(:getresources).and_return(records)
  end

  def stub_settings(body, status: Net::HTTPOK)
    response = status.new('1.1', status == Net::HTTPOK ? '200' : '404', 'OK')
    allow(response).to receive(:body).and_return(body)
    http = instance_double(Net::HTTP)
    allow(http).to receive(:get).and_return(response)
    allow(Net::HTTP).to receive(:start).and_yield(http)
    response
  end

  describe 'a provider that supports the synchronous flow' do
    before do
      stub_txt('domainconnect.godaddy.com')
      stub_settings({
        providerId: 'GoDaddy',
        providerDisplayName: 'GoDaddy',
        urlSyncUX: 'https://dcc.godaddy.com/manage/',
        width: 750, height: 750
      }.to_json)
    end

    it 'reports supported with the sync URL' do
      result = described_class.call('dealer.example')

      expect(result).to be_supported
      expect(result.provider_name).to eq('GoDaddy')
      expect(result.url_sync_ux).to eq('https://dcc.godaddy.com/manage')
    end
  end

  describe 'providers that cannot be used' do
    it 'reports unsupported when the domain advertises nothing' do
      allow(Resolv::DNS).to receive(:open).and_raise(Resolv::ResolvError)

      result = described_class.call('cloudflare-hosted.example')

      expect(result).not_to be_supported
      expect(result.error).to match(/does not advertise/i)
    end

    it 'reports unsupported when the settings endpoint offers no sync URL' do
      stub_txt('settings.example.com')
      stub_settings({ providerId: 'X', urlAPI: 'https://api.example.com' }.to_json)

      result = described_class.call('dealer.example')

      expect(result).not_to be_supported
      expect(result.error).to match(/synchronous/i)
    end

    it 'reports unsupported when the settings endpoint errors' do
      stub_txt('settings.example.com')
      stub_settings('nope', status: Net::HTTPNotFound)

      expect(described_class.call('dealer.example')).not_to be_supported
    end

    it 'reports unsupported rather than raising on malformed settings JSON' do
      stub_txt('settings.example.com')
      stub_settings('{not json')

      expect(described_class.call('dealer.example')).not_to be_supported
    end
  end

  describe 'the settings host is untrusted input' do
    # The host comes from a TXT record on a domain the tenant controls, so a crafted record
    # must not be able to make the server fetch an arbitrary address.
    %w[
      localhost:8080/admin
      169.254.169.254/latest/meta-data
      evil.com/../../internal
      host\nInjected:\sheader
    ].each do |malicious|
      it "refuses to fetch a host of #{malicious.inspect}" do
        stub_txt(malicious)
        expect(Net::HTTP).not_to receive(:start)

        expect(described_class.call('dealer.example')).not_to be_supported
      end
    end

    it 'allows a plain hostname' do
      stub_txt('domainconnect.godaddy.com')
      stub_settings({ urlSyncUX: 'https://x.example' }.to_json)

      expect(described_class.call('dealer.example')).to be_supported
    end
  end

  it 'reports unsupported for a blank domain without any lookup' do
    expect(Resolv::DNS).not_to receive(:open)

    expect(described_class.call('')).not_to be_supported
  end
end
