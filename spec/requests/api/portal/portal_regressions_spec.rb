# frozen_string_literal: true

require 'rails_helper'

# Defects found while auditing the buyer portal for a proxied demo session.
# Each block below reproduces one of them.
RSpec.describe 'Buyer portal regressions', type: :request do
  let(:company) { Company.create!(name: "Co-#{SecureRandom.hex(4)}", industry: 'manufactured_housing') }
  let(:account) { Account.create!(company: company, name: 'Buyer Account', status: 'active') }
  let(:contact) do
    Contact.create!(company: company, account: account, first_name: 'Barb', last_name: 'Jones',
                    email: "b-#{SecureRandom.hex(4)}@example.com")
  end
  let(:portal_access) do
    BuyerPortalAccess.create!(buyer: contact, company: company, email: contact.email,
                              password: 'Password123!', password_confirmation: 'Password123!',
                              portal_enabled: true)
  end

  # An admin "proxying in" gets exactly this token, with a one hour life.
  def proxy_token(expires_at: 1.hour.from_now)
    JsonWebToken.encode(
      { buyer_portal_access_id: portal_access.id, proxy: true, proxy_admin_id: 1, proxy_admin_name: 'Tom' },
      expires_at
    )
  end

  def headers(token) = { 'Authorization' => "Bearer #{token}" }

  describe 'portal auth failures are distinguishable' do
    # Both portal auth paths are exercised: quotes goes through
    # ApplicationController#authenticate_portal_buyer!, preferences through
    # Api::Portal::BaseController#authenticate_portal_contact. They used to
    # disagree, and neither could report expiry.
    %w[/api/portal/quotes /api/portal/preferences].each do |path|
      it "reports an expired proxy token as expired on #{path}" do
        get path, headers: headers(proxy_token(expires_at: 5.minutes.ago))

        expect(response).to have_http_status(:unauthorized)
        expect(JSON.parse(response.body)).to include('code' => 'token_expired')
      end

      it "reports a malformed token as invalid on #{path}" do
        get path, headers: headers('not-a-jwt')

        expect(response).to have_http_status(:unauthorized)
        expect(JSON.parse(response.body)).to include('code' => 'token_invalid')
      end

      it "reports a missing header as missing on #{path}" do
        get path

        expect(response).to have_http_status(:unauthorized)
        expect(JSON.parse(response.body)).to include('code' => 'token_missing')
      end
    end
  end

  describe 'GET /api/portal/communications/threads' do
    # `resources :communications` was declared first, so this path matched
    # communications#show with id="threads" and always 404'd.
    it 'reaches the threads action rather than #show' do
      expect(Rails.application.routes.recognize_path('/api/portal/communications/threads', method: :get))
        .to include(controller: 'api/portal/communications', action: 'threads')

      get '/api/portal/communications/threads', headers: headers(proxy_token)

      expect(response).to have_http_status(:ok)
    end
  end

  describe 'GET /api/portal/configurator/floor-plans' do
    let(:manufacturer) do
      Manufacturer.create!(name: "Mfr-#{SecureRandom.hex(3)}", industry_type: 'manufactured_housing')
    end
    let(:floor_plan) do
      FloorPlan.create!(name: 'The Monarch', model_code: "TM-#{SecureRandom.hex(3)}",
                        manufacturer: manufacturer,
                        base_price_low: 100_000, base_price_high: 140_000)
    end

    before do
      Setting.set('Company', company.id, 'configurator', { 'show_pricing' => true })
    end

    # CompanyFloorPlan has no base_price_* columns, so reading them raised
    # NoMethodError and the whole page 500'd as soon as a dealer had a plan
    # mapped with pricing on.
    it 'renders a mapped floor plan instead of raising' do
      company.company_floor_plans.create!(floor_plan: floor_plan, is_visible: true, retail_price: 129_900)

      get '/api/portal/configurator/floor-plans', headers: headers(proxy_token)

      expect(response).to have_http_status(:ok)
      plan = JSON.parse(response.body)['floor_plans'].first
      expect(plan['name']).to eq('The Monarch')
      expect(plan['base_price_low'].to_f).to eq(129_900.0)
    end

    it 'falls back to the plan base range when the dealer set no price' do
      company.company_floor_plans.create!(floor_plan: floor_plan, is_visible: true)

      get '/api/portal/configurator/floor-plans', headers: headers(proxy_token)

      expect(response).to have_http_status(:ok)
      expect(JSON.parse(response.body)['floor_plans'].first).to include('base_price_low')
    end
  end

  describe 'PATCH /api/portal/quotes/:id/accept' do
    def build_quote(status: 'sent', valid_until: 30.days.from_now.to_date)
      quote = Quote.create!(company: company, account: account, quote_number: "Q-#{SecureRandom.hex(3)}",
                            status: status, subtotal: 1000, tax: 100, total: 1100,
                            items: [{ description: 'Home', quantity: 1, unit_price: '1000.00', total: '1000.00' }],
                            valid_until: 30.days.from_now.to_date, sent_at: Time.current)
      # valid_until is validated into the future, so age it past the check.
      quote.update_column(:valid_until, valid_until)
      quote
    end

    it 'stamps accepted_at so the dealer can evidence the acceptance' do
      quote = build_quote

      patch "/api/portal/quotes/#{quote.id}/accept", headers: headers(proxy_token)

      expect(response).to have_http_status(:ok)
      expect(quote.reload.status).to eq('accepted')
      expect(quote.accepted_at).to be_present
    end

    it 'refuses an expired quote rather than letting the buyer lock in stale pricing' do
      quote = build_quote(valid_until: 1.day.ago.to_date)

      patch "/api/portal/quotes/#{quote.id}/accept", headers: headers(proxy_token)

      expect(response).to have_http_status(:unprocessable_entity)
      expect(JSON.parse(response.body)['error']).to match(/expired/i)
      expect(quote.reload.status).to eq('sent')
    end

    it 'stamps rejected_at on reject' do
      quote = build_quote

      patch "/api/portal/quotes/#{quote.id}/reject", headers: headers(proxy_token)

      expect(response).to have_http_status(:ok)
      expect(quote.reload.rejected_at).to be_present
    end
  end

  describe 'POST /api/portal/auth/forgot-password' do
    # The route pointed at auth#forgot_password, which does not exist, so the
    # path 404'd instead of mailing a reset.
    it 'routes to request_reset and issues a reset token' do
      portal_access

      post '/api/portal/auth/forgot-password',
           params: { email: portal_access.email }.to_json,
           headers: { 'Content-Type' => 'application/json' }

      expect(response).to have_http_status(:ok)
      expect(portal_access.reload.reset_token).to be_present
    end
  end
end
