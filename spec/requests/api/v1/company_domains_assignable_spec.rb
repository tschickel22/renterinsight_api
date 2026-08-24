# frozen_string_literal: true

require 'rails_helper'

# The landing page container used to be filtered out of the domain picker, so a
# tenant who added a subdomain in order to serve landing pages from it had
# nothing to select. The domain stayed unlinked, every request to it 404'd, and
# the only thing the UI said was "Nothing to show".
RSpec.describe 'Api::V1::CompanyDomains assignable websites', type: :request do
  let(:company) { Company.create!(name: "Co-#{SecureRandom.hex(4)}") }
  let(:user) do
    User.create!(email: "u-#{SecureRandom.hex(4)}@example.com", first_name: 'T', last_name: 'U',
                 password: 'Pass1234!', company_id: company.id, role: 'platform_admin')
  end
  let(:token) { JsonWebToken.encode(user_id: user.id, company_id: company.id) }
  let(:auth_headers) { { 'Authorization' => "Bearer #{token}", 'Content-Type' => 'application/json' } }
  let!(:location) { company.locations.create!(name: 'Main', active: true) }

  def website(kind:, name:)
    Website.create!(company_id: company.id, location_id: location.id, kind: kind, name: name,
                    slug: "#{kind}-#{SecureRandom.hex(3)}", status: :published,
                    published_at: Time.current)
  end

  it 'offers the landing page container alongside the dealer\'s own sites' do
    site = website(kind: 'site', name: 'Main Site')
    container = website(kind: 'marketing', name: 'Landing Pages')

    get '/api/v1/company-domains', headers: auth_headers
    expect(response).to have_http_status(:ok)

    offered = JSON.parse(response.body)['available_websites']
    expect(offered.map { |w| w['id'] }).to include(site.id, container.id)
  end

  it 'marks which one is the container, so the picker can say so' do
    website(kind: 'site', name: 'Main Site')
    container = website(kind: 'marketing', name: 'Landing Pages')

    get '/api/v1/company-domains', headers: auth_headers
    offered = JSON.parse(response.body)['available_websites'].index_by { |w| w['id'] }

    expect(offered[container.id]['landing_container']).to be true
    expect(offered.values.count { |w| w['landing_container'] }).to eq(1)
  end

  it 'still refuses another company\'s site' do
    other = Company.create!(name: 'Other')
    other_loc = other.locations.create!(name: 'Theirs', active: true)
    theirs = Website.create!(company_id: other.id, location_id: other_loc.id, kind: 'site',
                             name: 'Theirs', slug: "t-#{SecureRandom.hex(3)}", status: :published)

    get '/api/v1/company-domains', headers: auth_headers
    offered = JSON.parse(response.body)['available_websites']

    expect(offered.map { |w| w['id'] }).not_to include(theirs.id)
  end
end
