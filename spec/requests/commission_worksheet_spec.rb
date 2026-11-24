# frozen_string_literal: true

require 'rails_helper'

# The commission worksheet (every line, the plan, who gets paid) and the plan
# settings it lets an admin change: what the plan pays on, the split, at least
# and at most per deal, rates by gross band, one-off adjustments, when it is
# payable, and saving a change as a new version (2026-11-24).
RSpec.describe 'Commission worksheet and plan flexibility', type: :request do
  let(:company) { Company.create!(name: "CW-#{SecureRandom.hex(3)}", industry: 'manufactured_housing', use_rbac_system: false) }
  let(:admin) do
    company.users.create!(email: "a-#{SecureRandom.hex(3)}@example.com", first_name: 'Ada', last_name: 'Admin',
                          password: 'Pass1234!', role: 'admin', status: 'active')
  end
  let(:second) do
    company.users.create!(email: "b-#{SecureRandom.hex(3)}@example.com", first_name: 'Ben', last_name: 'Second',
                          password: 'Pass1234!', role: 'user', status: 'active')
  end
  let(:manager) do
    company.users.create!(email: "m-#{SecureRandom.hex(3)}@example.com", first_name: 'Mia', last_name: 'Manager',
                          password: 'Pass1234!', role: 'user', status: 'active')
  end
  let(:headers) { { 'Authorization' => "Bearer #{JsonWebToken.generate_access_token(admin)}" } }
  let(:buyer) { company.contacts.create!(first_name: 'Ana', last_name: 'Buyer') }
  let(:plan) { company.commission_plans.create!(name: 'Home only', is_active: true) }

  def component!(attrs = {})
    company.commission_components.create!({ name: '20% of house profit', component_type: 'percent_of_gross', gross_type: 'house_profit',
                                            rate: 0.2, commission_plan: plan, is_active: true, sequence: 1,
                                            applies_to_role: 'primary_salesperson' }.merge(attrs))
  end

  # Home 100,000 / 80,000; freight 3,000 charged; delivery and set 4,000 / 2,500;
  # steps 800 / 300; document fee 400; title fee 150.
  def deal!(stage: 'proposal')
    deal = company.deals.create!(name: 'Worksheet deal', stage: 'proposal', owner_id: admin.id, contact_id: buyer.id, commission_plan_id: plan.id)
    [['Aspen 3268', 100_000, 80_000, 'category:home'], ['Freight', 3000, 0, 'category:service'],
     ['Delivery and set', 4000, 2500, 'category:service'], ['Steps', 800, 300, 'category:accessory'],
     ['Document fee', 400, 0, 'category:fee'], ['Title fee', 150, 0, 'category:fee']].each do |name, price, cost, notes|
      deal.deal_products.create!(product_name: name, product_sku: "CUSTOM-#{SecureRandom.hex(3)}", unit_price: price, cost: cost, quantity: 1, notes: notes)
    end
    deal.update!(stage: stage) unless stage == 'proposal'
    deal.reload
  end

  def worksheet(deal, params = {})
    get "/api/crm/deals/#{deal.id}/commissions/worksheet", params: params, headers: headers
    expect(response).to have_http_status(:ok), response.body
    response.parsed_body
  end

  def row(figure, name) = figure['rows'].find { |r| r['name'] == name }

  it 'shows every line, which ones the plan pays on and why, and steps that land on the figure' do
    component!
    body = worksheet(deal!)
    figure = body['figures'].first
    expect(figure).to include('gross_type' => 'house_profit', 'amount' => 20_000.0)
    expect(row(figure, 'Aspen 3268')).to include('kind' => 'home', 'counts' => true, 'margin' => 20_000.0)
    expect(row(figure, 'Freight')).to include('kind' => 'freight', 'counts' => false)
    expect(row(figure, 'Freight')['reason']).to match(/No commission on freight/)
    expect(row(figure, 'Title fee')).to include('kind' => 'title_license', 'counts' => false)
    expect(figure['steps'].last).to include('amount' => 20_000.0, 'total' => true)
    expect(figure['steps'].map { |s| s['label'] }).not_to include(a_string_matching(/Other/))
    expect(body['totalCommission']).to eq(4000.0)
    expect(body['plan']['components'].first['description']).to eq('20.0% of house profit (the home only)')
  end

  it 'explains the fixed figures with the same lines their math uses (front gross)' do
    component!(gross_type: 'front')
    figure = worksheet(deal!)['figures'].first
    expect(figure['amount']).to eq(25_400.0) # everything but the title fee
    expect(row(figure, 'Freight')['counts']).to be(true)
    expect(figure['steps'].map { |s| s['label'] }).not_to include(a_string_matching(/Other/))
  end

  it 'pays on what the plan checklist says (plan_basis), and the worksheet shows the same figure' do
    component!(gross_type: 'plan_basis')
    deal = deal!
    expect(deal.commission_gross('plan_basis')).to eq(25_000) # home, freight, delivery, steps; no doc or title fee
    plan.update!(metadata: { 'pays_on' => { 'freight' => false, 'doc_fee' => true } })
    figure = worksheet(deal)['figures'].first
    expect(figure['amount']).to eq(22_400.0)
    expect(row(figure, 'Freight')).to include('counts' => false, 'reason' => 'The plan leaves freight charged to the buyer out')
    expect(row(figure, 'Document fee')['counts']).to be(true)
    expect(figure['steps'].last['amount']).to eq(22_400.0)
  end

  it 'tries another plan on the deal without saving it' do
    component!
    other = company.commission_plans.create!(name: 'Front gross', is_active: true)
    company.commission_components.create!(name: '10% of front', component_type: 'percent_of_gross', gross_type: 'front', rate: 0.1,
                                          commission_plan: other, is_active: true, applies_to_role: 'primary_salesperson')
    deal = deal!
    body = worksheet(deal, commission_plan_id: other.id)
    expect(body['plan']['name']).to eq('Front gross')
    expect(body['totalCommission']).to eq(2540.0)
    expect(body['savedPlanId']).to eq(plan.id)
    expect(deal.reload.commission_plan_id).to eq(plan.id)
  end

  it 'pays by gross bands, and at least or at most a set amount per deal' do
    c = component!(tiers: [{ up_to: 10_000, rate: 0.2 }, { rate: 0.25 }])
    deal = deal!
    expect(CommissionPaymentGeneratorService.new(deal).total_for_role(:primary_salesperson)).to eq(2000 + 2500) # 20% of 10k, 25% of the next 10k
    c.update!(tiers: [], max_amount: 3000)
    line = CommissionPaymentGeneratorService.new(deal.reload).lines_for_role(:primary_salesperson).first
    expect(line).to include(amount: 3000, note: 'at most $3,000.00 per deal')

    c.update!(max_amount: nil, min_amount: 250)
    deal.home_line_item.update!(cost: 101_000) # the home sells at a loss
    expect(CommissionPaymentGeneratorService.new(deal.reload).total_for_role(:primary_salesperson)).to eq(250)
    expect(c.calculation_description).to eq('20.0% of house profit (the home only), at least $250.00 per deal')
  end

  it 'refuses bands out of order and a floor above the ceiling' do
    c = component!
    expect(c.update(tiers: [{ up_to: 10_000, rate: 0.2 }, { up_to: 5000, rate: 0.25 }, { rate: 0.3 }])).to be(false)
    expect(c.update(tiers: [], min_amount: 500, max_amount: 100)).to be(false)
  end

  it "splits by the plan's share, and a deal can override it" do
    component!
    plan.update!(metadata: { 'split' => { 'primary_pct' => 60 } })
    deal = deal!
    deal.update!(secondary_salesperson_id: second.id)
    service = CommissionPaymentGeneratorService.new(deal.reload)
    expect(service.total_for_role(:primary_salesperson)).to eq(2400)
    expect(service.total_for_role(:secondary_salesperson)).to eq(1600)
    expect(service.lines_for_role(:secondary_salesperson).first[:note]).to include('split 60/40')

    deal.update!(commission_split_primary_pct: 75)
    expect(CommissionPaymentGeneratorService.new(deal.reload).total_for_role(:secondary_salesperson)).to eq(1000)
  end

  it 'adds a one-off adjustment to the estimate and to payments, for someone with or without a position' do
    component!
    deal = deal!
    post "/api/crm/deals/#{deal.id}/commissions/adjustments", params: { payee_user_id: manager.id, amount: 250, reason: 'Thin margin home' }, headers: headers
    expect(response).to have_http_status(:created), response.body
    body = worksheet(deal)
    mia = body['participants'].find { |p| p['userName'] == 'Mia Manager' }
    expect(mia['estimatedAmount']).to eq(250.0)
    expect(body['adjustments'].first).to include('reason' => 'Thin margin home', 'amount' => 250.0)
    expect(body['totalCommission']).to eq(4250.0)

    deal.update!(stage: company.won_stage_keys.first)
    CommissionSettings.set_payable_at(company, 'deal_closed')
    CommissionPaymentGeneratorService.new(deal.reload).recalculate
    payment = company.commission_payments.find_by(deal_id: deal.id, payee_user_id: manager.id)
    expect(payment.amount).to eq(250)
    expect(payment.calculation_details['line_items'].first['component_type']).to eq('adjustment')

    adj = deal.commission_adjustments.first
    delete "/api/crm/deals/#{deal.id}/commissions/adjustments/#{adj.id}", headers: headers
    expect(response).to have_http_status(:no_content)
    expect(payment.reload.status).to eq('cancelled')
  end

  it 'lets a plan say when its commissions are payable, over the company setting' do
    component!
    deal = deal!(stage: company.won_stage_keys.first)
    expect(deal).not_to be_commissions_payable # company pays at accounting approval
    plan.update!(metadata: { 'payable_at' => 'deal_closed' })
    expect(deal.reload).to be_commissions_payable
    expect(plan.update(metadata: { 'payable_at' => 'someday' })).to be(false)
  end

  it 'says what a change would move, and saves one as a new version from a date' do
    fee = company.commission_components.create!(name: 'Loan processor', component_type: 'flat_per_unit', flat_amount: 500,
                                                commission_plan: plan, is_active: true, applies_to_role: 'finance_manager')
    component!
    plan.update!(effective_date: Date.current - 30, metadata: { 'before_commission' => { 'fee_component_ids' => [fee.id] } })
    deal!

    get "/api/v1/commission-plans/#{plan.id}/usage", headers: headers
    expect(response.parsed_body).to include('openDeals' => 1, 'unpaidPayments' => 0, 'paidPayments' => 0)

    post "/api/v1/commission-plans/#{plan.id}/new-version", params: { starts_on: (Date.current + 1).iso8601 }, headers: headers
    expect(response).to have_http_status(:created), response.body
    copy = CommissionPlan.find(response.parsed_body['id'])
    expect(copy.effective_date).to eq(Date.current + 1)
    expect(plan.reload.expiration_date).to eq(Date.current)
    expect(copy.commission_components.count).to eq(2)
    expect(copy.fee_component_ids).to eq([copy.commission_components.find_by(name: 'Loan processor').id])

    post "/api/v1/commission-plans/#{plan.id}/new-version", params: { starts_on: (Date.current - 60).iso8601 }, headers: headers
    expect(response).to have_http_status(:unprocessable_entity)
  end
end
