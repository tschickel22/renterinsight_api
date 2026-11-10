# frozen_string_literal: true

require 'rails_helper'

# The setup instructions name the address partners post leads to. It must be
# the customer-facing API host in production, not the hosting provider's.
RSpec.describe 'GET /api/v1/api-keys/partner_info', type: :request do
  let(:company) { Company.create!(name: "Co-#{SecureRandom.hex(4)}", industry: 'manufactured_housing') }
  let(:admin) do
    User.create!(email: "a-#{SecureRandom.hex(4)}@example.com", first_name: 'A', last_name: 'A',
                 password: 'Pass1234!', company_id: company.id, role: 'platform_admin')
  end
  let(:headers) { { 'Authorization' => "Bearer #{JsonWebToken.encode(user_id: admin.id, company_id: company.id)}" } }

  around do |example|
    saved = ENV.to_h.slice('MCP_PUBLIC_BASE_URL', 'RAILS_API_URL')
    example.run
  ensure
    %w[MCP_PUBLIC_BASE_URL RAILS_API_URL].each { |k| saved.key?(k) ? ENV[k] = saved[k] : ENV.delete(k) }
  end

  it 'uses the public API host when one is set' do
    ENV['MCP_PUBLIC_BASE_URL'] = 'https://api.example.com/'
    ENV['RAILS_API_URL'] = 'https://old-host.example.net'

    get '/api/v1/api-keys/partner_info', headers: headers

    expect(response).to have_http_status(:ok)
    expect(JSON.parse(response.body)['leads_url']).to eq('https://api.example.com/api/partner/v1/leads')
  end

  it 'falls back to RAILS_API_URL' do
    ENV.delete('MCP_PUBLIC_BASE_URL')
    ENV['RAILS_API_URL'] = 'https://staging.example.net'

    get '/api/v1/api-keys/partner_info', headers: headers

    expect(JSON.parse(response.body)['leads_url']).to eq('https://staging.example.net/api/partner/v1/leads')
  end
end
