# frozen_string_literal: true

require 'rails_helper'

# Payment-grid endpoint: every cell is computed by the SAME DealDesk::Engine the solve/compare
# endpoints use — one Engine.compute per (term_months, cash_down) pair. No new math, no LLM.
# dealer_gross is attached per cell only for cost-viewers; the matrix is capped at 64 cells.
RSpec.describe 'Api::V1 Deal Desk payment grid', type: :request do
  let(:company) { Company.create!(name: "Co-#{SecureRandom.hex(4)}", industry: 'manufactured_housing') }
  let(:cost_viewer) do
    User.create!(email: "u-#{SecureRandom.hex(4)}@example.com", first_name: 'T', last_name: 'U',
                 password: 'Pass1234!', company_id: company.id, role: 'platform_admin')
  end
  let(:token) { JsonWebToken.encode(user_id: cost_viewer.id, company_id: company.id) }
  let(:headers) { { 'Authorization' => "Bearer #{token}", 'Content-Type' => 'application/json' } }

  let(:location) { company.locations.create!(name: 'Showroom', timezone: 'America/Denver') }
  let(:account) { company.accounts.create!(name: 'Buyer LLC') }
  let(:unit) do
    company.vehicles.create!(listing_type: 'manufactured_home', status: 'available', year: 2024,
                             make: 'Fleetwood', model: 'Aspire', serial_number: "SN-#{SecureRandom.hex(4)}",
                             bedrooms: 3, bathrooms: 2.0, sale_price: 70_000, dealer_cost: 50_000,
                             location_id: location.id, date_in_stock: 30.days.ago)
  end
  let(:deal) { company.deals.create!(name: 'Test Deal', account: account, vehicle: unit, location_id: location.id) }

  before { company.tenant_module_overrides.create!(module_key: 'sales.deal_desk', is_enabled: true) }

  def post_grid(body)
    post '/api/v1/deal_desk/scenarios/grid', params: body.to_json, headers: headers
    JSON.parse(response.body)
  end

  # Reconstruct the SAME base the controller derives when base_structure is omitted, so we can
  # assert each cell equals a direct Engine.compute for that (term, cash_down) pair.
  def derived_base
    DealDesk::CompareService.new(company: company, deal: deal).send(:default_base_structure)
                            .merge(price: deal.vehicle.sale_price.to_f,
                                   unit_cost: (deal.vehicle.cost || deal.vehicle.dealer_cost).to_f)
  end

  describe 'engine-computed cells (base derived from deal)' do
    it 'returns one cell per (term, cash_down) pair, each equal to direct Engine.compute' do
      body = post_grid(deal_id: deal.id, terms: [180, 240], cash_downs: [5_000, 10_000])
      expect(response).to have_http_status(:ok)

      grid = body['grid']
      expect(grid['terms']).to eq([180, 240])
      expect(grid['cash_downs']).to eq([5_000.0, 10_000.0])
      expect(grid['cells'].length).to eq(4)

      base = derived_base
      grid['cells'].each do |cell|
        expected = DealDesk::Engine.compute(base.merge(term_months: cell['term_months'], cash_down: cell['cash_down']))
        expect(cell['monthly_payment'].to_f).to be_within(0.01).of(expected.monthly_payment.to_f)
        expect(cell['amount_financed'].to_f).to be_within(0.01).of(expected.amount_financed.to_f)
        expect(cell['out_the_door'].to_f).to be_within(0.01).of(expected.out_the_door.to_f)
      end
    end
  end

  describe 'dealer_gross gating' do
    it 'includes dealer_gross for a cost-viewer' do
      body = post_grid(deal_id: deal.id, terms: [180], cash_downs: [5_000])
      expect(body['grid']['cells'].first).to have_key('dealer_gross')
    end

    it 'omits dealer_gross for a non-cost-viewer' do
      # RBAC location user with deal_desk:read but NOT deals view_cost_details.
      company.update!(use_rbac_system: true)
      rep = company.users.create!(email: "rep-#{SecureRandom.hex(3)}@ex.com", first_name: 'R', last_name: 'P',
                                  password: 'Pass1234!', role: 'user')
      Resource.seed_defaults; Action.seed_defaults; Scope.seed_defaults
      role = Role.create!(company_id: company.id, key: "rep-#{SecureRandom.hex(3)}", name: 'Rep', tier: 'location', active: true)
      Role.grant_deal_desk!(role, %w[read])
      rep.user_role_assignments.create!(role: role, company_id: company.id, tier: 'location', location: location)
      rep_token = JsonWebToken.encode(user_id: rep.id, company_id: company.id)

      post '/api/v1/deal_desk/scenarios/grid',
           params: { deal_id: deal.id, terms: [180], cash_downs: [5_000] }.to_json,
           headers: { 'Authorization' => "Bearer #{rep_token}", 'Content-Type' => 'application/json' }
      expect(response).to have_http_status(:ok)
      expect(JSON.parse(response.body)['grid']['cells'].first).not_to have_key('dealer_gross')
    end
  end

  describe 'runaway guard (64-cell cap)' do
    it 'rejects a matrix larger than 64 cells' do
      body = post_grid(deal_id: deal.id, terms: (1..9).to_a, cash_downs: (1..9).to_a) # 81 cells
      expect(response).to have_http_status(:unprocessable_entity)
      expect(body['error']).to match(/exceeds 64/)
    end

    it 'allows an 8x8 matrix (exactly 64 cells)' do
      terms = [12, 24, 36, 48, 60, 72, 84, 96]
      downs = [0, 1_000, 2_000, 3_000, 4_000, 5_000, 6_000, 7_000]
      body = post_grid(deal_id: deal.id, terms: terms, cash_downs: downs)
      expect(response).to have_http_status(:ok)
      expect(body['grid']['cells'].length).to eq(64)
    end
  end
end
