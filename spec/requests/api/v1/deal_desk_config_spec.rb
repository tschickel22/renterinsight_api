# frozen_string_literal: true

require 'rails_helper'

# Read-only config endpoints that populate the Deal Desk dropdowns.
RSpec.describe 'Api::V1 Deal Desk config endpoints', type: :request do
  let(:company) { Company.create!(name: "Co-#{SecureRandom.hex(4)}", industry: 'manufactured_housing') }
  let(:user) do
    User.create!(email: "u-#{SecureRandom.hex(4)}@example.com", first_name: 'T', last_name: 'U',
                 password: 'Pass1234!', company_id: company.id, role: 'platform_admin')
  end
  let(:token) { JsonWebToken.encode(user_id: user.id, company_id: company.id) }
  let(:headers) { { 'Authorization' => "Bearer #{token}" } }

  before do
    company.tenant_module_overrides.create!(module_key: 'sales.deal_desk', is_enabled: true)
    program = company.lender_programs.create!(lender_name: 'Aqua', program_name: 'Std', collateral_type: 'all', active: true, is_seeded: true)
    program.tiers.create!(tier_label: 'T1', fico_min: 720, rate: 6.99, max_term_months: 240, max_ltv: 1.25)
    company.fee_templates.create!(name: 'Doc Fee', fee_type: 'doc', default_amount: 599, taxable: false, is_seeded: true)
    company.fni_products.create!(name: 'VSC', product_type: 'service_contract', default_price: 2495, default_cost: 1400, is_seeded: true)
  end

  it 'lists lender programs with their tier matrix' do
    get '/api/v1/deal_desk/lender_programs', headers: headers
    expect(response).to have_http_status(:ok)
    prog = JSON.parse(response.body)['lender_programs'].first
    expect(prog['lender_name']).to eq('Aqua')
    expect(prog['tiers'].first['rate'].to_f).to eq(6.99)
  end

  it 'lists fee templates' do
    get '/api/v1/deal_desk/fee_templates', headers: headers
    expect(response).to have_http_status(:ok)
    expect(JSON.parse(response.body)['fee_templates'].map { |f| f['name'] }).to include('Doc Fee')
  end

  it 'lists F&I products, exposing default_cost to cost-viewers' do
    get '/api/v1/deal_desk/fni_products', headers: headers
    expect(response).to have_http_status(:ok)
    p = JSON.parse(response.body)['fni_products'].first
    expect(p['default_price'].to_f).to eq(2495.0)
    expect(p['default_cost'].to_f).to eq(1400.0) # platform_admin can view costs
  end

  it 'hides default_cost from a user without view_cost_details' do
    # RBAC location user with deal_desk:read but not deals view_cost_details.
    company.update!(use_rbac_system: true)
    rep = company.users.create!(email: "rep-#{SecureRandom.hex(3)}@ex.com", first_name: 'R', last_name: 'P',
                                password: 'Pass1234!', role: 'user')
    Resource.seed_defaults; Action.seed_defaults; Scope.seed_defaults
    role = Role.create!(company_id: company.id, key: "rep-#{SecureRandom.hex(3)}", name: 'Rep', tier: 'location', active: true)
    Role.grant_deal_desk!(role, %w[read])
    loc = company.locations.create!(name: 'Showroom', timezone: 'America/Denver')
    rep.user_role_assignments.create!(role: role, company_id: company.id, tier: 'location', location: loc)
    rep_token = JsonWebToken.encode(user_id: rep.id, company_id: company.id)

    get '/api/v1/deal_desk/fni_products', headers: { 'Authorization' => "Bearer #{rep_token}" }
    expect(response).to have_http_status(:ok)
    expect(JSON.parse(response.body)['fni_products'].first).not_to have_key('default_cost')
  end
end
