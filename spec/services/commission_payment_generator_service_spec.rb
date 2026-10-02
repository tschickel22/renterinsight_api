# frozen_string_literal: true

require 'rails_helper'

# The commission engine on real deals: volume bonuses, per unit pay, split
# deals, new/used and MH/RV limits, and the plan id on each payment.
RSpec.describe CommissionPaymentGeneratorService do
  let(:company) { Company.create!(name: "Comm-#{SecureRandom.hex(3)}", industry: 'manufactured_housing') }
  let(:rep) { user!('Rita') }
  let(:partner) { user!('Pat') }
  let(:plan) { company.commission_plans.create!(name: 'Sales', is_active: true) }
  let(:buyer) { company.contacts.create!(first_name: 'Ana', last_name: 'Buyer') }

  def user!(first)
    company.users.create!(email: "#{first.downcase}-#{SecureRandom.hex(3)}@example.com", first_name: first,
                          last_name: 'Rep', password: 'Pass1234!', role: 'user', status: 'active')
  end

  def component!(attrs)
    company.commission_components.create!({ commission_plan: plan, is_active: true,
                                            applies_to_role: 'primary_salesperson' }.merge(attrs))
  end

  def deal!(attrs = {})
    company.deals.create!({ name: "Deal #{SecureRandom.hex(2)}", stage: 'closed_won', owner_id: rep.id, contact_id: buyer.id,
                            commission_plan_id: plan.id, selling_price: 100_000, unit_cost: 80_000,
                            actual_close_date: Date.new(2026, 9, 15) }.merge(attrs))
  end

  def total(deal, role = :primary_salesperson)
    described_class.new(deal.reload).total_for_role(role).to_f
  end

  describe 'volume bonus' do
    before do
      component!(name: '5 a month', component_type: 'volume_bonus', flat_amount: 500, units_threshold: 3,
                 threshold_period: 'monthly')
    end

    it 'pays once, on the deal that brings the month to the threshold, in close date order' do
      deals = [1, 2, 3, 4].map { |day| deal!(actual_close_date: Date.new(2026, 9, day)) }
      expect(deals.map { |d| total(d) }).to eq([0.0, 0.0, 500.0, 0.0])
    end

    it 'counts each month on its own and only the person on the deal' do
      deal!(actual_close_date: Date.new(2026, 8, 30))
      deal!(actual_close_date: Date.new(2026, 8, 31))
      deal!(actual_close_date: Date.new(2026, 9, 1), owner_id: partner.id)
      third_in_sept = [deal!(actual_close_date: Date.new(2026, 9, 2)), deal!(actual_close_date: Date.new(2026, 9, 3))]
                      .then { deal!(actual_close_date: Date.new(2026, 9, 4)) }
      expect(total(third_in_sept)).to eq(500.0)
    end

    it 'ignores lost and deleted deals in the count' do
      deal!(actual_close_date: Date.new(2026, 9, 1), stage: 'closed_lost')
      deal!(actual_close_date: Date.new(2026, 9, 2)).update_column(:deleted_at, Time.current)
      second = [deal!(actual_close_date: Date.new(2026, 9, 3))].then { deal!(actual_close_date: Date.new(2026, 9, 4)) }
      expect(total(second)).to eq(0.0)
    end
  end

  it 'pays flat per unit times the quantity' do
    component!(name: 'Per home', component_type: 'flat_per_unit', flat_amount: 300)
    expect(total(deal!(quantity: 2))).to eq(600.0)
    expect(total(deal!(quantity: 1))).to eq(300.0)
  end

  it 'pays add-on commission on add-on gross even when an older component says commissionable front' do
    c = component!(name: 'Add-ons', component_type: 'addon_commission', rate: 0.1, gross_type: 'addon')
    c.update_column(:gross_type, 'commissionable_front')
    deal = deal!
    allow(deal).to receive(:addon_gross).and_return(BigDecimal('3000'))
    expect(described_class.new(deal).total_for_role(:primary_salesperson).to_f).to eq(300.0)
  end

  describe 'split deals' do
    before do
      component!(name: 'Front', component_type: 'percent_of_gross', gross_type: 'front', rate: 0.25)
      component!(name: 'Second only', component_type: 'flat_per_unit', flat_amount: 100,
                 applies_to_role: 'secondary_salesperson')
      component!(name: 'Everyone', component_type: 'flat_per_unit', flat_amount: 50, applies_to_role: 'all_participants')
    end

    it 'splits the primary components 50/50 and pays each person what is theirs, in real payments' do
      deal = deal!(secondary_salesperson_id: partner.id)
      front_share = (deal.front_gross.to_d * BigDecimal('0.25')).round(2)
      half = (front_share / 2).floor(2)

      payments = described_class.generate_for_deal(deal.reload).index_by(&:payee_user_id)
      expect(payments[rep.id].amount).to eq(front_share - half + 50)
      expect(payments[partner.id].amount).to eq(half + 100 + 50)
      expect(payments.values.map(&:commission_plan_id).uniq).to eq([plan.id])
      expect(payments[rep.id].calculation_details['line_items'].map { |l| l['component_id'] }).to all(be_present)
    end

    it 'pays a volume bonus in full to the primary on a split deal and says it was not split' do
      component!(name: 'First home', component_type: 'volume_bonus', flat_amount: 500, units_threshold: 1,
                 threshold_period: 'monthly')
      deal = deal!(secondary_salesperson_id: partner.id)
      engine = described_class.new(deal.reload)

      bonus = engine.lines_for_role(:primary_salesperson).find { |l| l[:component].name == 'First home' }
      expect(bonus[:amount]).to eq(500)
      expect(bonus[:note]).to include('reaches the 1 unit bonus',
                                      'not split; volume bonuses pay in full to the person who reached the threshold')
      expect(engine.lines_for_role(:secondary_salesperson).map { |l| l[:component].name }).not_to include('First home')
      front = engine.lines_for_role(:primary_salesperson).find { |l| l[:component].name == 'Front' }
      expect(front[:note]).to include('split 50/50 with the secondary salesperson')
    end

    it 'pays the primary in full with no secondary on the deal' do
      deal = deal!
      expect(total(deal)).to eq((deal.front_gross.to_d * BigDecimal('0.25')).round(2).to_f + 50)
    end
  end

  describe 'new/used and MH/RV limits' do
    before do
      component!(name: 'Used', component_type: 'flat_per_unit', flat_amount: 200, deal_type: 'used')
      component!(name: 'RV only', component_type: 'flat_per_unit', flat_amount: 75, vertical: 'rv')
      component!(name: 'MH', component_type: 'flat_per_unit', flat_amount: 25, vertical: 'mh')
    end

    it 'applies a used-only component when the deal type says used, and the vertical from the industry' do
      expect(total(deal!(deal_type: 'used'))).to eq(225.0)
    end

    it 'leaves a used-only component off a deal whose kind is unknown (a financing type)' do
      expect(total(deal!(deal_type: 'Chattel'))).to eq(25.0)
    end
  end

  describe 'Deal#commission_deal_type and #commission_vertical' do
    it "reads the unit's condition when deal_type holds the financing type" do
      deal = company.deals.new(deal_type: 'FHA', vehicle: Vehicle.new(condition: 'Used'))
      expect(deal.commission_deal_type).to eq('used')
      expect(company.deals.new(deal_type: 'FHA').commission_deal_type).to be_nil
      expect(company.deals.new(deal_type: 'New').commission_deal_type).to eq('new')
    end

    it 'maps manufactured_home and the company industry to mh' do
      expect(company.deals.new(vertical: 'manufactured_home').commission_vertical).to eq('mh')
      expect(company.deals.new.commission_vertical).to eq('mh')
      expect(company.deals.new(vertical: 'RV').commission_vertical).to eq('rv')
    end
  end

  describe 'CommissionPlan.for_salesperson' do
    before do
      Resource.seed_defaults
      Action.seed_defaults
      Scope.seed_defaults
    end

    it 'matches a role based plan on the RBAC role key the plan form offers' do
      role = Role.create!(company_id: company.id, key: 'sales_rep', name: 'Sales Rep', tier: 'company', active: true)
      rep.user_role_assignments.create!(role: role, company_id: company.id, tier: 'company')
      role_plan = company.commission_plans.create!(name: 'Reps', is_active: true, assigned_role: 'sales_rep')
      company.commission_plans.create!(name: 'Default', is_active: true, is_default: true)

      expect(CommissionPlan.for_salesperson(rep, company)).to eq(role_plan)
      expect(company.deals.create!(name: 'Auto', stage: 'proposal', owner_id: rep.id, contact_id: buyer.id).commission_plan).to eq(role_plan)
    end

    it 'still prefers a plan assigned to the person' do
      mine = company.commission_plans.create!(name: 'Mine', is_active: true, assigned_user_id: rep.id)
      company.commission_plans.create!(name: 'Users', is_active: true, assigned_role: 'user')
      expect(CommissionPlan.for_salesperson(rep, company)).to eq(mine)
    end
  end

  describe 'CommissionComponent#paid?' do
    it 'is true once a payment carries the component, and for older payments by plan and name' do
      c = component!(name: 'Front', component_type: 'percent_of_gross', gross_type: 'front', rate: 0.25)
      expect(c.paid?).to be(false)

      described_class.generate_for_deal(deal!.reload)
      expect(c.paid?).to be(true)

      old = component!(name: 'Legacy', component_type: 'flat_per_unit', flat_amount: 10)
      company.commission_payments.create!(deal_id: deal!.id, payee_user_id: rep.id, amount: 10, status: 'pending',
                                          calculation_details: { 'plan_id' => plan.id,
                                                                 'line_items' => [{ 'description' => 'Legacy', 'amount' => 10 }] })
      expect(old.paid?).to be(true)
    end
  end
end
