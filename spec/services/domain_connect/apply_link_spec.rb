# frozen_string_literal: true

require 'rails_helper'

RSpec.describe DomainConnect::ApplyLink do
  let(:company) { Company.create!(name: "Co-#{SecureRandom.hex(3)}") }
  let(:domain) do
    company.company_domains.create!(
      hostname: 'dealer.example', email_enabled: true,
      ses_dkim_tokens: %w[tok1 tok2 tok3],
      ses_mail_from_domain: 'mail.dealer.example'
    )
  end

  let(:key) { OpenSSL::PKey::RSA.new(2048) }

  let(:discovery) do
    DomainConnect::Discovery::Result.new(
      supported: true, provider_id: 'GoDaddy',
      url_sync_ux: 'https://dcc.godaddy.com/manage', provider_name: 'GoDaddy'
    )
  end

  before do
    allow(ENV).to receive(:[]).and_call_original
    allow(ENV).to receive(:[]).with('DOMAIN_CONNECT_PROVIDER_ID').and_return('dealertide.com')
    allow(ENV).to receive(:[]).with('DOMAIN_CONNECT_PRIVATE_KEY').and_return(key.to_pem)
  end

  def build = described_class.for(domain: domain, discovery: discovery)

  it 'builds an apply URL against the providers sync endpoint' do
    expect(build).to start_with(
      'https://dcc.godaddy.com/manage/v2/domainTemplates/providers/dealertide.com/services/email/apply?'
    )
  end

  it 'passes each DKIM token as a template variable' do
    query = CGI.parse(URI.parse(build).query)

    expect(query['dkim1']).to eq(['tok1'])
    expect(query['dkim2']).to eq(['tok2'])
    expect(query['dkim3']).to eq(['tok3'])
    expect(query['domain']).to eq(['dealer.example'])
  end

  it 'sends the MAIL FROM label rather than the fully qualified name' do
    expect(CGI.parse(URI.parse(build).query)['mailfrom']).to eq(['mail'])
  end

  it 'signs exactly the query string it sends, so the two cannot drift' do
    query = URI.parse(build).query
    signed_part, tail = query.split('&key=')
    signature = Base64.decode64(CGI.unescape(tail.split('&sig=').last))

    expect(key.public_key.verify(OpenSSL::Digest::SHA256.new, signature, signed_part)).to be true
  end

  it 'names the key record so the provider knows which key to check' do
    expect(CGI.parse(URI.parse(build).query)['key']).to eq(['_dck1'])
  end

  context 'when auto-apply is not possible' do
    it 'returns nil when no signing key is configured' do
      allow(ENV).to receive(:[]).with('DOMAIN_CONNECT_PRIVATE_KEY').and_return(nil)

      expect(build).to be_nil
    end

    it 'returns nil when we have no provider id yet' do
      allow(ENV).to receive(:[]).with('DOMAIN_CONNECT_PROVIDER_ID').and_return(nil)

      expect(build).to be_nil
    end

    it 'returns nil when the DNS provider does not support Domain Connect' do
      unsupported = DomainConnect::Discovery::Result.new(supported: false, error: 'nope')

      expect(described_class.for(domain: domain, discovery: unsupported)).to be_nil
    end

    it 'refuses a partial DKIM set rather than writing DNS that cannot verify' do
      domain.update!(ses_dkim_tokens: %w[tok1 tok2])

      expect(build).to be_nil
    end

    it 'returns nil when email sending is not enabled' do
      domain.update!(email_enabled: false)

      expect(build).to be_nil
    end

    it 'returns nil rather than raising on a malformed private key' do
      allow(ENV).to receive(:[]).with('DOMAIN_CONNECT_PRIVATE_KEY').and_return('not a key')

      expect(build).to be_nil
    end
  end
end
