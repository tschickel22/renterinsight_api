# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'Api::V1::DealDeskScenarios', type: :request do
  let(:company) { Company.create!(name: "Co-#{SecureRandom.hex(4)}", industry: 'manufactured_housing') }
  let(:user) do
    User.create!(email: "u-#{SecureRandom.hex(4)}@example.com", first_name: 'T', last_name: 'U',
                 password: 'Pass1234!', company_id: company.id, role: 'platform_admin')
  end
  let(:token) { JsonWebToken.encode(user_id: user.id, company_id: company.id) }
  let(:headers) { { 'Authorization' => "Bearer #{token}", 'Content-Type' => 'application/json' } }

  let(:location) { company.locations.create!(name: 'Showroom', timezone: 'America/Denver') }
  let(:account) { company.accounts.create!(name: 'Buyer LLC') }
  let(:unit) do
    company.vehicles.create!(listing_type: 'manufactured_home', status: 'available', year: 2024,
                             make: 'Fleetwood', model: 'Aspire', serial_number: "SN-#{SecureRandom.hex(4)}",
                             bedrooms: 3, bathrooms: 2.0, sale_price: 70_000, dealer_cost: 50_000,
                             location_id: location.id, date_in_stock: 30.days.ago)
  end
  let(:deal) do
    company.deals.create!(name: 'Test Deal', account: account, vehicle: unit, location_id: location.id)
  end

  def created_scenario
    post '/api/v1/deal_desk/scenarios',
         params: { scenario: { deal_id: deal.id, vehicle_id: unit.id, term_months: 180,
                               cash_down: 5_000, tax_rate: 0.05, tax_mode: 'full_price',
                               fees: { doc: 599 } } }.to_json,
         headers: headers
    JSON.parse(response.body)['scenario']
  end

  describe 'POST /scenarios (autosave + compute)' do
    it 'creates and computes outputs from the engine' do
      s = created_scenario
      expect(response).to have_http_status(:created)
      expect(s['monthly_payment'].to_f).to be > 0
      expect(s['amount_financed'].to_f).to be > 0
      expect(s['apr'].to_f).to eq(company.default_finance_rate)
      expect(s['status']).to eq('active')
    end
  end

  describe 'GET /scenarios (list — desk workspace fetch)' do
    it 'includes deal_desk_writeback_mode so the workspace is mode-aware (default on_close)' do
      created_scenario
      get '/api/v1/deal_desk/scenarios', params: { deal_id: deal.id }, headers: headers
      expect(response).to have_http_status(:ok)
      expect(JSON.parse(response.body)['deal_desk_writeback_mode']).to eq('on_close')
    end
  end

  describe 'POST /scenarios/solve' do
    it 'reverse-solves a lever for a target payment' do
      post '/api/v1/deal_desk/scenarios/solve',
           params: { deal_id: deal.id, lever: 'term', target_payment: 600 }.to_json, headers: headers
      expect(response).to have_http_status(:ok)
      expect(JSON.parse(response.body)['solve']['lever']).to eq('term')
    end
  end

  describe 'POST /scenarios/compare' do
    it 'returns the anchor and candidate set' do
      deal # ensure anchor
      post '/api/v1/deal_desk/scenarios/compare',
           params: { deal_id: deal.id, target_payment: 650, include_other_locations: true }.to_json,
           headers: headers
      expect(response).to have_http_status(:ok)
      body = JSON.parse(response.body)['compare']
      expect(body['anchor']['vehicle_id']).to eq(unit.id)
      expect(body).to have_key('candidates')
    end
  end

  describe 'POST /scenarios/:id/select (flag only — does NOT mutate the deal)' do
    it 'marks selected without writing economics back to the deal' do
      s = created_scenario
      post "/api/v1/deal_desk/scenarios/#{s['id']}/select", headers: headers
      expect(response).to have_http_status(:ok)
      expect(JSON.parse(response.body)['scenario']['status']).to eq('selected')
      deal.reload
      # down_payment is written ONLY by apply/write-back (selling_price is auto-synced from
      # the vehicle at deal creation, so it's not a reliable "untouched" indicator).
      expect(deal.down_payment.to_f).to eq(0.0)  # scenario cash_down (5_000) NOT written back
      expect(deal.stage).to eq('qualification')  # close pipeline untouched
    end

    it 'enforces a single selected scenario per deal (selecting B demotes A to active)' do
      a = created_scenario
      b = created_scenario
      post "/api/v1/deal_desk/scenarios/#{a['id']}/select", headers: headers
      expect(DealDeskScenario.find(a['id']).status).to eq('selected')

      post "/api/v1/deal_desk/scenarios/#{b['id']}/select", headers: headers
      expect(response).to have_http_status(:ok)
      expect(DealDeskScenario.find(a['id']).status).to eq('active')   # demoted
      expect(DealDeskScenario.find(b['id']).status).to eq('selected')
    end
  end

  describe 'POST /scenarios/:id/apply (deliberate write-back to the deal)' do
    it 'writes the scenario structure back to the deal' do
      s = created_scenario
      post "/api/v1/deal_desk/scenarios/#{s['id']}/apply", headers: headers
      expect(response).to have_http_status(:ok)
      expect(JSON.parse(response.body)['applied']).to eq(true)
      deal.reload
      expect(deal.selling_price.to_f).to eq(70_000.0)
      expect(deal.down_payment.to_f).to eq(5_000.0)
      expect(deal.stage).to eq('qualification') # still no close/GL side effects
    end
  end

  describe 'POST /scenarios/:id/generate_quote' do
    it 'creates a quote from the scenario' do
      s = created_scenario
      post "/api/v1/deal_desk/scenarios/#{s['id']}/generate_quote", headers: headers
      expect(response).to have_http_status(:created)
      expect(JSON.parse(response.body)['quote']['public_token']).to be_present
    end
  end

  describe 'GET /scenarios/:id/summary.pdf' do
    it 'returns a branded PDF' do
      s = created_scenario
      get "/api/v1/deal_desk/scenarios/#{s['id']}/summary.pdf", headers: headers
      expect(response).to have_http_status(:ok)
      expect(response.media_type).to eq('application/pdf')
      expect(response.body[0, 5]).to eq('%PDF-')
    end
  end

  describe 'DELETE /scenarios/:id (expire, never hard-delete)' do
    it 'expires rather than destroying' do
      s = created_scenario
      delete "/api/v1/deal_desk/scenarios/#{s['id']}", headers: headers
      expect(response).to have_http_status(:ok)
      expect(DealDeskScenario.find(s['id']).status).to eq('expired')
    end
  end
end
