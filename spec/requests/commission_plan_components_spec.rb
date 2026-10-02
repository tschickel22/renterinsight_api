# frozen_string_literal: true

require 'rails_helper'

# Taking a component off a plan (it used to raise on an undefined
# association) and the components page test calculator (it used to run a
# second engine that disagreed with what is paid).
RSpec.describe 'Commission plan components', type: :request do
  let(:company) { Company.create!(name: "Comm-#{SecureRandom.hex(3)}", industry: 'manufactured_housing', use_rbac_system: false) }
  let(:admin) do
    company.users.create!(email: "a-#{SecureRandom.hex(3)}@example.com", first_name: 'Ada', last_name: 'Admin',
                          password: 'Pass1234!', role: 'admin', status: 'active')
  end
  let(:headers) { { 'Authorization' => "Bearer #{JsonWebToken.generate_access_token(admin)}" } }
  let(:plan) { company.commission_plans.create!(name: 'Sales', is_active: true) }
  let(:buyer) { company.contacts.create!(first_name: 'Ana', last_name: 'Buyer') }
  let!(:front) do
    company.commission_components.create!(name: 'Front', component_type: 'percent_of_gross', gross_type: 'front',
                                          rate: 0.25, commission_plan: plan, is_active: true, sequence: 1,
                                          applies_to_role: 'primary_salesperson')
  end

  def deal!
    company.deals.create!(name: 'Sold', stage: 'closed_won', owner_id: admin.id, contact_id: buyer.id,
                          commission_plan_id: plan.id, selling_price: 100_000, unit_cost: 80_000,
                          actual_close_date: Date.current)
  end

  describe 'removing a component from a plan' do
    it 'takes an unpaid component off the plan' do
      delete "/api/v1/commission-plans/#{plan.id}/remove-component/#{front.id}", headers: headers
      expect(response).to have_http_status(:ok), response.body
      expect(front.reload.commission_plan_id).to be_nil
    end

    it 'refuses a component that has been paid' do
      CommissionPaymentGeneratorService.generate_for_deal(deal!.reload)
      delete "/api/v1/commission-plans/#{plan.id}/remove-component/#{front.id}", headers: headers
      expect(response).to have_http_status(:unprocessable_entity)
      expect(front.reload.commission_plan_id).to eq(plan.id)
    end
  end

  describe 'test calculate' do
    it 'answers with what the paying engine pays for that component on the deal' do
      deal = deal!.reload
      post "/api/v1/commission-components/#{front.id}/calculate", params: { deal_id: deal.id }, headers: headers
      expect(response).to have_http_status(:ok), response.body

      body = response.parsed_body
      expected = CommissionPaymentGeneratorService.new(deal).total_for_role(:primary_salesperson).to_f
      expect(body['total_commission']).to eq(expected)
      expect(body['line_items'].first).to include('component_id' => front.id, 'component_name' => 'Front')
      expect(body.dig('plan', 'primary_salesperson_total')).to eq(expected)
      expect(body['deal_economics']).to include('front_gross', 'pack', 'quantity')
    end
  end
end
