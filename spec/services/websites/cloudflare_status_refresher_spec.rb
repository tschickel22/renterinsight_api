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
end
