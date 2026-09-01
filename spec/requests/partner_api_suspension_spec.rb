# frozen_string_literal: true

require 'rails_helper'

# The partner API descends from ActionController::API, not ApplicationController,
# so the before_action that locks staff out of a suspended tenant is not in its
# chain at all. Measured on a live suspension: six keys carrying leads
# read+write stayed fully usable after every human had been locked out.
RSpec.describe 'Partner API under a suspended company', type: :request do
  let(:company) { create(:company, status: company_status) }
  # created_by_user is a required association on ApiKey.
  let(:creator) do
    User.create!(
      email: "owner-#{SecureRandom.hex(4)}@example.com",
      first_name: 'Owner',
      company_id: company.id,
      status: 'active',
      password: 'secret123'
    )
  end

  let(:api_key) do
    ApiKey.create!(
      name: 'Facebook Leads',
      key: "pk_#{SecureRandom.hex(16)}",
      company: company,
      status: 'active',
      # Left blank on purpose. The real keys carry leads read+write, but
      # validate_permissions checks against a resources table this suite does
      # not seed, and the company gate fires before authorize_permission! either
      # way , which is the point: no permission set can get past a suspension.
      created_by_user: creator
    )
  end

  let(:headers) { { 'Authorization' => "Bearer #{api_key.key}" } }

  context 'when the company is active' do
    let(:company_status) { 'active' }

    it 'lets the key through' do
      get '/api/partner/v1/ping', headers: headers
      expect(response).to have_http_status(:ok)
    end
  end

  %w[suspended cancelled].each do |status|
    context "when the company is #{status}" do
      let(:company_status) { status }

      it 'refuses the key' do
        get '/api/partner/v1/ping', headers: headers

        expect(response).to have_http_status(:forbidden)
        expect(JSON.parse(response.body)['code']).to eq('company_suspended')
      end

      # The partner controllers expose index and show, so an unchecked key is a
      # route OUT for the lead database, not merely a route in.
      it 'refuses reads as well as writes' do
        get '/api/partner/v1/leads', headers: headers
        expect(response).to have_http_status(:forbidden)

        post '/api/partner/v1/leads', headers: headers, params: { first_name: 'A' }
        expect(response).to have_http_status(:forbidden)
      end

      # The property the whole design turns on: a hold is reversed by one flag,
      # with no second piece of state to remember. Revoking the keys would have
      # left a reinstated customer with silently dead lead intake.
      it 'works again the moment the company is active, with the key untouched' do
        get '/api/partner/v1/ping', headers: headers
        expect(response).to have_http_status(:forbidden)

        company.update!(status: 'active')

        get '/api/partner/v1/ping', headers: headers
        expect(response).to have_http_status(:ok)
        expect(api_key.reload.status).to eq('active')
      end
    end
  end
end
