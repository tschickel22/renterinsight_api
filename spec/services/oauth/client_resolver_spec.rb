# frozen_string_literal: true

require 'rails_helper'

# Client ID Metadata Documents: an app uses an HTTPS URL as its client_id and
# publishes its name and redirect URIs there. ChatGPT prefers this to dynamic
# registration. We only fetch from the AI apps' own hosts.
RSpec.describe Oauth::ClientResolver do
  let(:url) { 'https://chatgpt.com/oauth/abc123/client.json' }

  def stub_document(**body)
    response = Net::HTTPOK.new('1.1', '200', 'OK')
    allow(response).to receive(:body).and_return(body.to_json)
    http = instance_double(Net::HTTP, request: response)
    allow(Net::HTTP).to receive(:start).and_yield(http)
  end

  it 'registers the app from its document' do
    stub_document(client_id: url, client_name: 'ChatGPT',
                  redirect_uris: ['https://chatgpt.com/connector_platform_oauth_redirect'],
                  token_endpoint_auth_method: 'none')

    client = described_class.find!(url)

    expect(client).to have_attributes(registration_type: 'cimd', client_name: 'ChatGPT',
                                      redirect_uris: ['https://chatgpt.com/connector_platform_oauth_redirect'])
  end

  it 'never fetches from a host that is not one of the AI apps' do
    expect(Net::HTTP).not_to receive(:start)

    expect { described_class.find!('https://attacker.example.com/client.json') }
      .to raise_error(Oauth::Error, /not on an allowed host/)
  end

  it 'refuses a document that names a different client_id' do
    stub_document(client_id: 'https://chatgpt.com/oauth/other/client.json', client_name: 'X',
                  redirect_uris: ['https://chatgpt.com/connector_platform_oauth_redirect'])

    expect { described_class.find!(url) }.to raise_error(Oauth::Error, /does not name itself/)
  end

  it 'refuses a document whose redirects point off the allowlist' do
    stub_document(client_id: url, client_name: 'X', redirect_uris: ['https://evil.example.com/cb'])

    expect { described_class.find!(url) }.to raise_error(Oauth::Error, /not an allowed redirect/)
  end

  it 'reuses a fresh copy instead of fetching every time' do
    stub_document(client_id: url, client_name: 'ChatGPT', redirect_uris: ['https://chatgpt.com/connector_platform_oauth_redirect'])
    described_class.find!(url)

    expect(Net::HTTP).not_to receive(:start)
    described_class.find!(url)
  end
end
