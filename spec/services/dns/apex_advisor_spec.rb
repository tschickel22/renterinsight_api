# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Dns::ApexAdvisor do
  def stub_registrar(key, name, apex_alias:, forwarding_hint: nil)
    allow(Dns::Registrar).to receive(:for).and_return(
      { key: key, name: name, supports_apex_alias: apex_alias, forwarding_hint: forwarding_hint }
    )
  end

  describe 'subdomains' do
    it 'raises no concern for www' do
      result = described_class.for('www.sunshine-rv.com')

      expect(result).not_to be_apex
      expect(result).to be_workable
      expect(result.strategy).to eq(:subdomain)
    end

    it 'raises no concern for a deeper subdomain' do
      expect(described_class.for('shop.sunshine-rv.com')).not_to be_apex
    end
  end

  describe 'a bare domain on a provider without ALIAS' do
    before { stub_registrar('godaddy', 'GoDaddy', apex_alias: false, forwarding_hint: 'Use Forwarding.') }

    # The failure this prevents: ownership verifies, everything looks correct, and the
    # certificate silently never issues because DNS forbids a CNAME at a zone apex.
    it 'reports it as not workable' do
      result = described_class.for('sunshine-rv.com')

      expect(result).to be_apex
      expect(result).not_to be_workable
      expect(result.strategy).to eq(:www_with_forwarding)
    end

    it 'names the provider rather than blaming DNS in the abstract' do
      expect(described_class.for('sunshine-rv.com').headline).to include('GoDaddy')
    end

    it 'suggests the www hostname that will actually work' do
      expect(described_class.for('sunshine-rv.com').suggested_hostname).to eq('www.sunshine-rv.com')
    end

    it 'includes the provider specific forwarding hint' do
      expect(described_class.for('sunshine-rv.com').detail).to include('Use Forwarding.')
    end
  end

  describe 'a bare domain on a provider with ALIAS' do
    before { stub_registrar('cloudflare', 'Cloudflare', apex_alias: true) }

    it 'reports it as workable' do
      result = described_class.for('sunshine-rv.com')

      expect(result).to be_apex
      expect(result).to be_workable
      expect(result.strategy).to eq(:alias)
    end

    it 'warns that a plain CNAME will be rejected' do
      expect(described_class.for('sunshine-rv.com').detail).to match(/ALIAS|ANAME|flattened/i)
    end
  end

  describe 'multi-part public suffixes' do
    before { stub_registrar('godaddy', 'GoDaddy', apex_alias: false) }

    # sunshine-rv.co.uk has three labels but is still a bare domain. Counting dots alone
    # would read it as a subdomain and wave through a hostname that cannot work.
    it 'treats co.uk as a bare domain' do
      expect(described_class.for('sunshine-rv.co.uk')).to be_apex
    end

    it 'treats www on a co.uk domain as a subdomain' do
      expect(described_class.for('www.sunshine-rv.co.uk')).not_to be_apex
    end
  end

  describe 'input handling' do
    it 'tolerates a pasted URL' do
      stub_registrar('godaddy', 'GoDaddy', apex_alias: false)

      expect(described_class.for('https://sunshine-rv.com/')).to be_apex
    end

    it 'raises no concern for a blank hostname' do
      expect(described_class.for('')).to be_workable
    end
  end
end
