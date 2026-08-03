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
  let(:auth_headers) { { 'Authorization' => "Bearer #{token}", 'Content-Type' => 'application/json' } }

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

  # This controller used to override set_company_scope with
  #
  #   company_id = request.headers['X-Company-ID'] || params[:company_id]
  #
  # and no check of who was asking, so any authenticated user could name any company and
  # operate on that tenant's websites. It now inherits ApplicationController's version.
  describe 'tenant isolation' do
    let(:other_company) { Company.create!(name: "Other-#{SecureRandom.hex(4)}") }
    let(:other_location) { other_company.locations.create!(name: 'Austin') }
    let!(:other_website) do
      other_company.websites.create!(location_id: other_location.id, name: 'Not Yours',
                                     slug: "s-#{SecureRandom.hex(4)}")
    end
    let(:tenant_user) do
      User.create!(email: "t-#{SecureRandom.hex(4)}@example.com", first_name: 'T', last_name: 'U',
                   password: 'Pass1234!', company_id: company.id, role: 'admin')
    end
    let(:tenant_token) { JsonWebToken.encode(user_id: tenant_user.id, company_id: company.id) }

    it 'refuses a company named in the X-Company-ID header by a non platform admin' do
      post "/api/v1/websites/#{other_website.id}/publish",
           headers: { 'Authorization' => "Bearer #{tenant_token}",
                      'X-Company-ID' => other_company.id.to_s }

      expect(response).not_to have_http_status(:ok)
      expect(other_website.reload.status).not_to eq('published')
    end

    it 'refuses a company named in a request param' do
      post "/api/v1/websites/#{other_website.id}/publish?company_id=#{other_company.id}",
           headers: { 'Authorization' => "Bearer #{tenant_token}" }

      expect(response).not_to have_http_status(:ok)
      expect(other_website.reload.status).not_to eq('published')
    end

    it 'never returns another tenants website in a listing' do
      get '/api/v1/websites', headers: { 'Authorization' => "Bearer #{tenant_token}",
                                         'X-Company-ID' => other_company.id.to_s }

      expect(response.body).not_to include('Not Yours')
    end

    # A platform admin naming another company IS allowed to, and that is the whole reason
    # the header exists. Asserted so the fix above is not mistaken for closing it off.
    it 'still lets a platform admin switch companies with the header' do
      get '/api/v1/websites', headers: { 'Authorization' => "Bearer #{token}",
                                         'X-Company-ID' => other_company.id.to_s }

      expect(response).to have_http_status(:ok)
      expect(JSON.parse(response.body)['items'].map { |w| w['id'] }).to include(other_website.id)
    end

    # The override answered 401 "Missing company context" whenever X-Company-ID was absent,
    # and the frontend only sends that header once a platform admin has switched companies.
    # Reaching the permission check at all is the point here: it means the company resolved
    # from the JWT.
    it 'resolves the company from the JWT when no company header is sent' do
      get '/api/v1/websites', headers: { 'Authorization' => "Bearer #{tenant_token}" }

      expect(response).not_to have_http_status(:unauthorized)
      expect(response.body).not_to include('Missing company context')
    end
  end
end
