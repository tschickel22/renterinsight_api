# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Websites::CloudflareStatusRefresher do
  let(:company) { Company.create!(name: "Co-#{SecureRandom.hex(3)}") }
  let(:ownership) { { 'type' => 'TXT', 'name' => '_cf-custom-hostname.www.x.example', 'value' => 'own' } }
  let(:domain) do
    company.company_domains.create!(
      hostname: 'www.x.example', web_enabled: true, cloudflare_custom_hostname_id: 'cf-1',
      verification_records: [ownership,
                             { 'type' => 'TXT', 'name' => '_acme-challenge.www.x.example',
                               'value' => 'old-token', 'kind' => 'certificate' }]
    )
  end

  before { allow(Dns::Lookup).to receive(:cname).and_return([]) }

  # Cloudflare reissues certificate tokens when it retries. Keeping the first set would show
  # a dealer values that no longer validate anything.
  it 'replaces the certificate records and keeps the ownership record' do
    service = instance_double(CloudflareSaasService, revalidate_custom_hostname: true,
                                                     check_custom_hostname_status: {})
    allow(service).to receive(:parse_custom_hostname_response).and_return(
      verification_status: 'active', ssl_status: 'pending_validation',
      certificate_records: [{ 'type' => 'TXT', 'name' => '_acme-challenge.www.x.example',
                              'value' => 'new-token', 'ttl' => 600, 'kind' => 'certificate' }]
    )

    described_class.call(domain, service: service)

    expect(domain.reload.ownership_records).to eq([ownership])
    expect(domain.certificate_records.map { |r| r['value'] }).to eq(%w[new-token])
  end

  # www.cbhms.com, 2026-11-13: added under TXT validation while the old site was live, then
  # pointed at us. Nobody published the challenge records, so it sat without a certificate.
  describe 'moving to HTTP validation once the domain points at us' do
    let(:service) do
      instance_double(CloudflareSaasService, check_custom_hostname_status: {},
                                             parse_custom_hostname_response: {
                                               verification_status: 'active', ssl_status: 'pending_validation',
                                               certificate_records: []
                                             })
    end

    before { domain.update!(cname_target: 'origin.mydealertide.com') }

    it 'asks for HTTP validation when the CNAME already points here' do
      allow(Dns::Lookup).to receive(:cname).with('www.x.example', zone: 'x.example')
                                           .and_return(['origin.mydealertide.com.'])
      expect(service).to receive(:revalidate_custom_hostname).with('cf-1', ssl_method: 'http')

      described_class.call(domain, service: service)
    end

    # The www.easyhomesource.com bug: HTTP before the switch can never pass.
    it 'keeps the current method while the CNAME still points at the old host' do
      allow(Dns::Lookup).to receive(:cname).and_return(['oldhost.example.net'])
      expect(service).to receive(:revalidate_custom_hostname).with('cf-1', ssl_method: nil)

      described_class.call(domain, service: service)
    end

    it 'leaves a domain alone once its certificate is issued' do
      domain.update!(ssl_status: 'active')
      expect(Dns::Lookup).not_to receive(:cname)
      expect(service).to receive(:revalidate_custom_hostname).with('cf-1', ssl_method: nil)

      described_class.call(domain, service: service)
    end
  end
end
