# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'Api::V1::Websites publishing', type: :request do
  let(:company) { Company.create!(name: "Co-#{SecureRandom.hex(4)}") }
  let(:location) { company.locations.create!(name: 'Denver') }
  let(:user) do
    User.create!(email: "u-#{SecureRandom.hex(4)}@example.com", first_name: 'T', last_name: 'U',
                 password: 'Pass1234!', company_id: company.id, role: 'platform_admin')
  end
  let(:token) { JsonWebToken.encode(user_id: user.id, company_id: company.id) }
  # This controller overrides set_company_scope and reads X-Company-ID rather than the
  # company already carried in the JWT, so the header is required here specifically.
  let(:auth_headers) do
    { 'Authorization' => "Bearer #{token}", 'Content-Type' => 'application/json',
      'X-Company-ID' => company.id.to_s }
  end

  let(:website) do
    company.websites.create!(location_id: location.id, name: 'Sunshine RV',
                             slug: "s-#{SecureRandom.hex(4)}")
  end

  # The builder's publish panel read `result.website.status` off this response and died with
  # "Cannot read properties of undefined", because the endpoint returns the website itself
  # and always has. The two other callers ignore the return value, so nothing caught it.
  describe 'POST /api/v1/websites/:id/publish' do
    it 'returns the website itself, not a wrapper' do
      post "/api/v1/websites/#{website.id}/publish", headers: auth_headers

      expect(response).to have_http_status(:ok)
      body = JSON.parse(response.body)
      expect(body).not_to have_key('website')
      expect(body['id']).to eq(website.id)
      expect(body['status']).to eq('published')
      expect(body['published_at']).to be_present
    end

    # Published and reachable are different things, and the panel needs to say which.
    it 'reports the address so the builder can tell reachable from merely published' do
      post "/api/v1/websites/#{website.id}/publish", headers: auth_headers

      expect(JSON.parse(response.body)).to have_key('domain_status')
    end

    it 'reports no address when no domain is assigned' do
      post "/api/v1/websites/#{website.id}/publish", headers: auth_headers

      expect(JSON.parse(response.body)['domain_status']['state']).to eq('none')
    end

    it 'reports the assigned hostname once a domain is verified' do
      company.company_domains.create!(hostname: 'sunshine-rv.test', website_id: website.id,
                                      verification_status: 'active', web_enabled: true)

      post "/api/v1/websites/#{website.id}/publish", headers: auth_headers

      expect(JSON.parse(response.body)['domain_status']['hostname']).to eq('sunshine-rv.test')
    end

    # update without the bang returns false on a validation failure, and this rendered 200
    # with an unchanged record either way: a publish that did not happen reported success.
    it 'reports a failure rather than a 200 with an unchanged record' do
      allow_any_instance_of(Website).to receive(:update).and_return(false)

      post "/api/v1/websites/#{website.id}/publish", headers: auth_headers

      expect(response).to have_http_status(:unprocessable_entity)
    end
  end

  describe 'POST /api/v1/websites/:id/unpublish' do
    it 'returns the website itself, not a wrapper' do
      website.publish!

      post "/api/v1/websites/#{website.id}/unpublish", headers: auth_headers

      expect(response).to have_http_status(:ok)
      body = JSON.parse(response.body)
      expect(body).not_to have_key('website')
      expect(body['status']).to eq('unpublished')
    end
  end
end
