# frozen_string_literal: true

require 'rails_helper'

# Four reports were regrouped by audience rather than by the page they live on.
# Two risks come with that: a role that could open a report loses it, or a role
# that gains one sees margin it should not.
RSpec.describe 'Report resource split', type: :request do
  let(:company) do
    Company.create!(name: "Co-#{SecureRandom.hex(4)}", industry: 'manufactured_housing',
                    use_rbac_system: true)
  end
  let(:location) { company.locations.create!(name: 'Showroom', timezone: 'America/Denver') }

  before do
    Resource.seed_defaults
    Action.seed_defaults
    Scope.seed_defaults
  end

  # A user holding exactly the resources named, at read/all.
  #
  # Note on cost visibility: `view_cost_details` is not a Scope row, it is a
  # string passed to has_permission?, and that method treats a stored scope of
  # 'all' as satisfying any requested scope. So `deals:read:all` already grants
  # cost visibility, and the only way to be denied it is to hold no deals read
  # at all. That is the behaviour asserted below, not the behaviour one might
  # assume from the name.
  def user_with(*resource_keys)
    role = Role.create!(company_id: company.id, key: "r-#{SecureRandom.hex(3)}",
                        name: 'Scoped', tier: 'company', active: true)
    read = Action.find_by!(key: 'read')
    all_scope = Scope.find_by!(key: 'all')

    resource_keys.each do |key|
      RolePermission.create!(role: role, resource: Resource.find_by!(key: key),
                             action: read, scope: all_scope, granted: true)
    end

    user = company.users.create!(email: "u-#{SecureRandom.hex(4)}@example.com", first_name: 'U',
                                 last_name: 'Ser', password: 'Pass1234!', role: 'user')
    user.user_role_assignments.create!(role: role, company_id: company.id, tier: 'company')
    Rails.cache.clear
    user
  end

  def headers_for(user)
    { 'Authorization' => "Bearer #{JsonWebToken.encode(user_id: user.id, company_id: company.id)}" }
  end

  describe 'which key opens which report' do
    it 'opens Deal Profitability for sales_reports and denies financial_reports alone' do
      get '/api/v1/accounting/reports/deal_profitability', headers: headers_for(user_with('sales_reports'))
      expect(response).to have_http_status(:ok)

      get '/api/v1/accounting/reports/deal_profitability', headers: headers_for(user_with('financial_reports'))
      expect(response).to have_http_status(:forbidden)
    end

    it 'opens Floor Plan for inventory_reports and denies financial_reports alone' do
      get '/api/v1/accounting/reports/floor_plan', headers: headers_for(user_with('inventory_reports'))
      expect(response).to have_http_status(:ok)

      get '/api/v1/accounting/reports/floor_plan', headers: headers_for(user_with('financial_reports'))
      expect(response).to have_http_status(:forbidden)
    end

    it 'keeps the general ledger on financial_reports' do
      get '/api/v1/accounting/reports/trial_balance', headers: headers_for(user_with('financial_reports'))
      expect(response).to have_http_status(:ok)

      get '/api/v1/accounting/reports/trial_balance', headers: headers_for(user_with('sales_reports'))
      expect(response).to have_http_status(:forbidden)
    end

    # These two rode on `deals`, so anyone who could see a deal could see the
    # whole stock list and every rep's pipeline.
    it 'no longer opens the stock list for a plain deals reader' do
      get '/api/v1/inventory/reports/stock_list', headers: headers_for(user_with('inventory_reports'))
      expect(response).to have_http_status(:ok)

      get '/api/v1/inventory/reports/stock_list', headers: headers_for(user_with('deals'))
      expect(response).to have_http_status(:forbidden)
    end

    it 'moves the salesperson GP pipeline onto sales_reports' do
      get '/api/v1/inventory/reports/salesperson_gp_pipeline', headers: headers_for(user_with('sales_reports'))
      expect(response).to have_http_status(:ok)

      get '/api/v1/inventory/reports/salesperson_gp_pipeline', headers: headers_for(user_with('deals'))
      expect(response).to have_http_status(:forbidden)
    end
  end

  describe 'Deal Profitability cost columns' do
    it 'hides cost and margin from a viewer with no deals read at all' do
      get '/api/v1/accounting/reports/deal_profitability', headers: headers_for(user_with('sales_reports'))

      body = JSON.parse(response.body)
      expect(body['can_view_costs']).to be false
      expect(body['summary']).not_to include('total_gross_profit', 'gross_margin', 'total_net_profit')
    end

    # Documents the live semantics rather than the intended ones: deals:read:all
    # satisfies view_cost_details because 'all' matches any requested scope, so
    # a typical sales role sees margin here. Tightening that is a change to core
    # authorisation and would remove access from real users, so it is a decision
    # to take deliberately, not a side effect of moving a report.
    it 'shows them to anyone holding deals read at scope all' do
      get '/api/v1/accounting/reports/deal_profitability',
          headers: headers_for(user_with('sales_reports', 'deals'))

      body = JSON.parse(response.body)
      expect(body['summary']).to include('total_gross_profit')
    end
  end
end
