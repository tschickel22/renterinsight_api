# frozen_string_literal: true

require 'rails_helper'

# The deal's commission card and the payment fixes from the Easy Homesource review.
RSpec.describe 'Deal commissions', type: :request do
  let(:company) { Company.create!(name: "Comm-#{SecureRandom.hex(3)}", industry: 'manufactured_housing', use_rbac_system: false) }
  let(:admin) { person('Ada', 'admin') }
  let(:rep) { person('Rita') }
  let(:partner) { person('Pat') }
  let(:headers) { { 'Authorization' => "Bearer #{JsonWebToken.generate_access_token(admin)}" } }
  let(:plan) { company.commission_plans.create!(name: 'Sales', is_active: true) }
  let(:buyer) { company.contacts.create!(first_name: 'Ana', last_name: 'Buyer') }
  let!(:front) do
    company.commission_components.create!(name: 'Agent', component_type: 'percent_of_gross', gross_type: 'front', rate: 0.2,
                                          commission_plan: plan, is_active: true, applies_to_role: 'primary_salesperson')
  end

  def person(first, role = 'user')
    company.users.create!(email: "#{first.downcase}-#{SecureRandom.hex(3)}@example.com", first_name: first, last_name: 'T',
                          password: 'Pass1234!', role: role, status: 'active')
  end

  def deal!(attrs = {})
    company.deals.create!({ name: 'Sold', stage: 'closed_won', owner_id: rep.id, contact_id: buyer.id, commission_plan_id: plan.id,
                            selling_price: 100_000, unit_cost: 70_000, actual_close_date: Date.current }.merge(attrs))
  end

  def preview(deal, body = {})
    post "/api/crm/deals/#{deal.id}/commissions/preview", params: body, headers: headers, as: :json
    expect(response).to have_http_status(:ok), response.body
    response.parsed_body
  end

  describe 'preview' do
    it 'answers without a crash when the deal has no cost' do
      body = preview(deal!(unit_cost: nil, stage: 'proposal'))
      expect(body).to include('costEntered' => false, 'totalCommission' => 0.0)
    end

    it 'pays a house profit plan on the home alone, and splits it between two agents' do
      house = company.commission_plans.create!(name: 'House', is_active: true)
      company.commission_components.create!(name: 'Agent', component_type: 'percent_of_gross', gross_type: 'house_profit', rate: 0.19,
                                            commission_plan: house, is_active: true, applies_to_role: 'primary_salesperson')
      company.commission_components.create!(name: 'Processor', component_type: 'flat_per_unit', flat_amount: 1000, commission_plan: house,
                                            is_active: true, applies_to_role: 'finance_manager')
      deal = deal!(commission_plan_id: house.id, stage: 'proposal', pack_amount: 0)
      deal.deal_products.create!(product_name: 'Home', unit_price: 100_000, cost: 70_000, quantity: 1, total: 100_000, notes: 'category:home')
      deal.deal_products.create!(product_name: 'Delivery', unit_price: 9_000, cost: 4_000, quantity: 1, total: 9_000, notes: 'category:service')

      alone = preview(deal.reload)
      expect(alone['totalCommission']).to eq(5700.0)

      both = preview(deal, secondary_salesperson_id: partner.id, finance_manager_id: admin.id)
      expect(both['participants'].to_h { |p| [p['role'], p['estimatedAmount']] })
        .to eq('primary_salesperson' => 2850.0, 'secondary_salesperson' => 2850.0, 'finance_manager' => 1000.0)
      expect(both['totalCommission']).to eq(6700.0)
    end

    it 'still offers the plans when the deal owner is not on this account' do
      outsider = Company.create!(name: "Other-#{SecureRandom.hex(3)}", industry: 'manufactured_housing', use_rbac_system: false)
                        .users.create!(email: "out-#{SecureRandom.hex(3)}@example.com", first_name: 'Out', last_name: 'T',
                                       password: 'Pass1234!', role: 'user', status: 'active')
      body = preview(deal!(stage: 'proposal'), owner_id: outsider.id)

      expect(body['availablePlans'].map { |p| p['id'] }).to include(plan.id)
      expect(body['participants']).to eq([])
      expect(body['totalCommission']).to eq(0.0)
    end

    it 'follows the pack and trade on screen before they are saved' do
      deal = deal!(stage: 'proposal', pack_amount: 0)
      expect(preview(deal, trade_payoff: 10_000)['totalCommission']).to eq(4000.0)
      expect(deal.reload.trade_payoff.to_f).to eq(0.0)
    end

    it 'prices people and a plan chosen on screen without saving them' do
      other = company.commission_plans.create!(name: 'Other', is_active: true)
      company.commission_components.create!(name: 'Desk', component_type: 'flat_per_unit', flat_amount: 500, commission_plan: other,
                                            is_active: true, applies_to_role: 'desk_manager')
      deal = deal!
      body = preview(deal, commission_plan_id: other.id, desk_manager_id: partner.id)

      expect(body['planId']).to eq(other.id)
      expect(body['participants'].map { |p| [p['role'], p['estimatedAmount']] }).to eq([['desk_manager', 500.0]])
      expect(body['unpaidPositions'].map { |p| p['role'] }).to eq(['primary_salesperson'])
      expect(deal.reload).to have_attributes(commission_plan_id: plan.id, desk_manager_id: nil)
    end

    it 'never prices or names a person from another company' do
      other = Company.create!(name: "Else-#{SecureRandom.hex(3)}", industry: 'manufactured_housing', use_rbac_system: false)
      stranger = other.users.create!(email: "s-#{SecureRandom.hex(3)}@example.com", first_name: 'Stranger', last_name: 'T',
                                     password: 'Pass1234!', role: 'user', status: 'active')
      body = preview(deal!, secondary_salesperson_id: stranger.id)

      expect(body['participants'].map { |p| p['userId'] }).not_to include(stranger.id)
      expect(body.to_json).not_to include('Stranger')
    end
  end

  it 'pays one person in two positions for both, in one payment' do
    company.commission_components.create!(name: 'Desk', component_type: 'flat_per_unit', flat_amount: 500, commission_plan: plan,
                                          is_active: true, applies_to_role: 'desk_manager')
    payments = CommissionPaymentGeneratorService.generate_for_deal(deal!(desk_manager_id: rep.id).reload)
    expect(payments.map(&:amount)).to eq([6500])
  end

  it 'records the commission on the deal for the accrual' do
    deal = deal!
    CommissionPaymentGeneratorService.generate_for_deal(deal.reload)
    expect(deal.reload.commission_amount).to eq(6000)
  end

  describe 'paying at close' do
    it 'waits for GL approval by default' do
      deal = deal!
      expect(deal.commission_payments).to be_empty
      post "/api/crm/deals/#{deal.id}/commissions/refresh", headers: headers, as: :json
      expect(response).to have_http_status(:unprocessable_entity)
    end

    it 'makes payments when the deal closes, and lists them without GL approval' do
      put '/api/v1/commission-plans/settings', params: { payable_at: 'deal_closed' }, headers: headers, as: :json
      expect(response).to have_http_status(:ok), response.body

      deal = deal!(stage: 'proposal')
      deal.update!(stage: 'closed_won')
      expect(deal.commission_payments.reload.map(&:amount)).to eq([6000])

      get '/api/v1/commission-payments', headers: headers
      expect(response.parsed_body['payments'].size).to eq(1)
    end

    it 'brings an unpaid payment up to date after the cost is corrected' do
      CommissionSettings.set_payable_at(company, 'deal_closed')
      deal = deal!(stage: 'proposal')
      deal.update!(stage: 'closed_won')
      deal.update!(unit_cost: 80_000, home_cost: 80_000)

      post "/api/crm/deals/#{deal.id}/commissions/refresh", headers: headers, as: :json
      expect(response).to have_http_status(:ok), response.body
      expect(deal.commission_payments.reload.map(&:amount)).to eq([4000])
    end
  end

  describe 'payments' do
    let(:payment) { CommissionPaymentGeneratorService.generate_for_deal(deal!.reload).first }

    it 'finishes a partial payment' do
      payment.approve!(approved_by: admin)
      payment.mark_paid!(paid_by: admin, payment_method: 'check', amount_paid: 1000)
      expect(payment.can_mark_paid?).to be(true)

      payment.mark_paid!(paid_by: admin, payment_method: 'check')
      expect(payment.reload).to have_attributes(status: 'paid', amount_paid: 6000, remaining_balance: 0)
    end

    it 'exports an unpaid payment' do
      post '/api/v1/commission-payments/export', params: { payment_ids: [payment.id] }, headers: headers, as: :json
      expect(response).to have_http_status(:ok), response.body
    end

    it 'reports by the date paid, not the day it was recorded' do
      payment.approve!(approved_by: admin)
      payment.mark_paid!(paid_by: admin, payment_method: 'check', paid_date: Date.new(2025, 12, 30))

      get '/api/v1/commission-payments/reports-data', params: { start_date: '2025-01-01', end_date: '2025-12-31' }, headers: headers
      expect(response.parsed_body.dig('summary', 'totalPayments')).to eq(1)
      get '/api/v1/commission-payments/reports-data', params: { start_date: "#{Date.current.year}-01-01", end_date: Date.current.to_s }, headers: headers
      expect(response.parsed_body.dig('summary', 'totalPayments')).to eq(0)
    end
  end

  it 'does not take a component off the plan it is on' do
    other = company.commission_plans.create!(name: 'Other', is_active: true)
    post "/api/v1/commission-plans/#{other.id}/add-component", params: { component_id: front.id }, headers: headers, as: :json
    expect(response).to have_http_status(:not_found)
    expect(front.reload.commission_plan_id).to eq(plan.id)
  end
end
