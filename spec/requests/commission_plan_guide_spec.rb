# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'Commission plan guide and test', type: :request do
  let(:company) { Company.create!(name: "Guide-#{SecureRandom.hex(3)}", industry: 'manufactured_housing', use_rbac_system: false) }
  let(:admin) { company.users.create!(email: "a-#{SecureRandom.hex(3)}@example.com", first_name: 'Ada', last_name: 'T', password: 'Pass1234!', role: 'admin', status: 'active') }
  let(:headers) { { 'Authorization' => "Bearer #{JsonWebToken.generate_access_token(admin)}" } }
  let(:plan) { company.commission_plans.create!(name: 'EHS', is_active: false) }
  let!(:agent) do
    company.commission_components.create!(name: 'Agent', component_type: 'percent_of_gross', gross_type: 'house_profit', rate: 0.2,
                                          commission_plan: plan, is_active: true, applies_to_role: 'primary_salesperson')
  end
  let!(:fee) do
    company.commission_components.create!(name: 'financing fee', component_type: 'flat_per_unit', flat_amount: 1000, commission_plan: plan,
                                          is_active: true, applies_to_role: 'finance_manager')
  end

  let(:buyer) { company.contacts.create!(first_name: 'Ana', last_name: 'Buyer') }

  before { plan.update!(metadata: { before_commission: { company_fee_percent: 5, fee_component_ids: [fee.id] } }) }

  def test_deal(body)
    post "/api/v1/commission-plans/#{plan.id}/test-deal", params: body, headers: headers, as: :json
    response.parsed_body
  end

  it 'explains the plan in words, with the amounts the engine pays' do
    get "/api/v1/commission-plans/#{plan.id}/guide", headers: headers

    expect(response).to have_http_status(:ok), response.body
    expect(response.parsed_body['summary']).to eq([
      'On a deal with $30,000.00 of profit:',
      '$1,500.00 5% admin fee stays with the company.',
      '$1,000.00 financing fee goes to the finance manager, only when someone holds that position.',
      'The salesperson earns 20% of $27,500.00, the house profit left after fees: $5,500.00.',
      'With a second salesperson, they split it evenly: $2,750.00 and $2,750.00.'
    ])
    expect(response.parsed_body['warnings']).to eq([])
    expect(response.parsed_body['checklist'].find { |c| c['key'] == 'activate' }['done']).to be(false)
  end

  it 'pays on the full profit when no fees are set to come off first' do
    plan.update!(metadata: { before_commission: { company_fee_percent: 0, fee_component_ids: [] } })
    get "/api/v1/commission-plans/#{plan.id}/guide", headers: headers

    expect(response.parsed_body['summary']).to eq([
      'On a deal with $30,000.00 of profit:',
      'The salesperson earns 20% of $30,000.00 of house profit: $6,000.00.',
      'The finance manager earns $1,000.00 per home, only when someone holds that position.',
      'With a second salesperson, they split it evenly: $3,000.00 and $3,000.00.'
    ])
    body = test_deal(home_price: 85_000, home_cost: 55_000, positions: %w[finance_manager])
    expect(body['payouts'].to_h { |p| [p['role'], p['amount']] }).to eq('primary_salesperson' => 6000.0, 'finance_manager' => 1000.0)
  end

  it 'warns when a plan with fees pays on more than the home, and when two rates stack' do
    agent.update!(gross_type: 'commissionable_front')
    company.commission_components.create!(name: 'Second', component_type: 'percent_of_gross', gross_type: 'house_profit', rate: 0.2,
                                          commission_plan: plan, is_active: true, applies_to_role: 'secondary_salesperson')
    get "/api/v1/commission-plans/#{plan.id}/guide", headers: headers

    expect(response.parsed_body['warnings'].join(' ')).to include('Choose House Profit', '40% in total')
  end

  it 'pays out a sample deal on an inactive plan and saves nothing' do
    expect do
      body = test_deal(home_price: 85_000, home_cost: 55_000, addon_price: 8_000, addon_cost: 5_000, pack: 0, positions: %w[finance_manager secondary_salesperson bogus])
      expect(body['figures']).to include('houseProfit' => 30_000.0, 'addonProfit' => 3_000.0)
      expect(body['payouts'].to_h { |p| [p['role'], p['amount']] })
        .to eq('primary_salesperson' => 2750.0, 'secondary_salesperson' => 2750.0, 'finance_manager' => 1000.0)
      expect(body['total']).to eq(6500.0)
      expect(body['dealershipKeeps']).to eq(26_500.0)
    end.not_to(change { [Deal.count, DealProduct.count, CommissionPayment.count] })
  end

  it 'prices a real deal on this plan without changing the deal' do
    other = company.commission_plans.create!(name: 'Other', is_active: true)
    deal = company.deals.create!(name: 'Real', stage: 'proposal', contact_id: buyer.id, owner_id: admin.id, commission_plan_id: other.id, selling_price: 100_000, unit_cost: 70_000, pack_amount: 0)

    body = test_deal(deal_id: deal.id)

    expect(body['payouts'].map { |p| [p['person'], p['amount']] }).to eq([[admin.name, 5700.0]])
    expect(deal.reload.commission_plan_id).to eq(other.id)
  end

  it 'lists samples and real deals, and never another company deal' do
    mine = company.deals.create!(name: 'Mine', stage: 'proposal', contact_id: buyer.id, selling_price: 1)
    elsewhere = Company.create!(name: "X-#{SecureRandom.hex(3)}", industry: 'rv')
    theirs = elsewhere.deals.create!(name: 'Theirs', stage: 'proposal', selling_price: 1, contact_id: elsewhere.contacts.create!(first_name: 'B', last_name: 'C').id)

    get "/api/v1/commission-plans/#{plan.id}/test-options", headers: headers
    expect(response.parsed_body['samples'].size).to eq(3)
    expect(response.parsed_body['deals'].map { |d| d['id'] }).to eq([mine.id])

    test_deal(deal_id: theirs.id)
    expect(response).to have_http_status(:not_found)
  end
end
