# frozen_string_literal: true

require 'rails_helper'
require_relative '../../support/mcp_connector_helpers'

# Commission plans through the connector: a dealer designs a plan with the AI,
# tests it on example deals and saves it as an inactive draft. What anyone
# earned never comes through, and nothing here activates a plan.
RSpec.describe 'MCP commission plan tools', :mcp, type: :request do
  before do
    seed_rbac!
    TenantModuleOverride.create!(company_id: company.id, module_key: 'management.commissions', is_enabled: true)
  end

  let(:company) { connector_company }
  let(:grants) do
    { 'commission_plans' => %w[read create update], 'commission_components' => %w[read create update] }
  end
  let(:user) { connector_user(company, grants) }
  let(:token) { connect!(user)['access_token'] }
  let(:buyer) { company.contacts.create!(first_name: 'Ana', last_name: 'Diaz') }

  let(:components) do
    [{ name: 'Front', component_type: 'percent_of_gross', gross_type: 'commissionable_front', rate: 25,
       applies_to_role: 'primary_salesperson' },
     { name: 'Manager override', component_type: 'percent_of_gross', gross_type: 'total', rate: 0.05,
       applies_to_role: 'sales_manager' },
     { name: 'Add-ons', component_type: 'addon_commission', rate: 10, applies_to_role: 'primary_salesperson' }]
  end

  def plan!(attrs = {})
    company.commission_plans.create!({ name: 'Existing', is_active: true, is_default: true }.merge(attrs)).tap do |p|
      company.commission_components.create!(name: 'Front 20', component_type: 'percent_of_gross', gross_type: 'front',
                                            rate: 0.2, applies_to_role: 'primary_salesperson', commission_plan: p,
                                            is_active: true, sequence: 1)
    end
  end

  describe 'reading' do
    it 'lists plans with status, assignment and components in plain words' do
      plan!
      result, error = call_tool(token, 'list_commission_plans')
      expect(error).to be_falsey
      item = result['items'].first
      expect(item).to include('status' => 'current', 'assignment' => { 'kind' => 'company default' })
      expect(item['components'].first).to include('pays' => '20.0% of Front gross', 'rate_percent' => 20.0)
      expect(item['url']).to end_with("/commissions/plans/#{company.commission_plans.first.id}")
    end

    it "cannot reach another company's plan" do
      other = connector_company.commission_plans.create!(name: 'Theirs', is_active: false)
      _, error, text = call_tool(token, 'get_commission_plan', id: "commission_plan:#{other.id}")
      expect(error).to be(true)
      expect(text).to include('No record')
    end

    it 'refuses without the plan module or the permission' do
      TenantModuleOverride.where(company_id: company.id, module_key: 'management.commissions').update_all(is_enabled: false)
      _, error, text = call_tool(token, 'list_commission_plans')
      expect(error).to be(true)
      expect(text).to include('Commission Engine is not part')

      TenantModuleOverride.where(company_id: company.id, module_key: 'management.commissions').update_all(is_enabled: true)
      outsider = connect!(connector_user(company, { 'leads' => %w[read] }))['access_token']
      _, error, text = call_tool(outsider, 'list_commission_plans')
      expect(error).to be(true)
      expect(text).to include('commission plans')
    end

    it 'never offers a tool for commissions earned or payments' do
      names = mcp_post(token, 'tools/list').dig('result', 'tools').map { |t| t['name'] }
      expect(names).to include('list_commission_plans', 'simulate_commission_plan', 'create_commission_plan_draft')
      expect(names.grep(/payment|earn|my_commission|activate/)).to be_empty
      expect(names.grep(/commission/)).to all(match(/plan/))
    end

    it 'hides the plan writes from a read-only connection' do
      read_only = connect!(user, allow_write: false)['access_token']
      names = mcp_post(read_only, 'tools/list').dig('result', 'tools').map { |t| t['name'] }
      expect(names).to include('list_commission_plans', 'simulate_commission_plan')
      expect(names).not_to include('create_commission_plan_draft', 'update_commission_plan_draft')
    end
  end

  describe 'drafting' do
    it 'saves an inactive, non-default plan with its components and reads rates as percents' do
      result, error, text = call_tool(token, 'create_commission_plan_draft',
                                      name: 'Sales 2027', components: components, wants_default: true)
      expect(error).to be_falsey, text

      plan = company.commission_plans.find_by!(name: 'Sales 2027')
      expect(plan).to have_attributes(is_active: false, is_default: false)
      comps = plan.commission_components.ordered
      expect(comps.map(&:rate).map(&:to_f)).to eq([0.25, 0.05, 0.1])
      expect(comps.last.gross_type).to eq('addon')
      expect(result['rate_notes']).to include('Front: rate read as 25.0%', 'Manager override: rate read as 5.0%')
      expect(result['default_note']).to include('admin makes it the company default')
      expect(result['next_step']).to include('INACTIVE', "/commissions/plans/#{plan.id}")
      expect(McpChange.where(record_type: 'CommissionPlan', record_id: plan.id, action: 'created')).to exist
    end

    it 'lists every fix and saves nothing when the design is invalid' do
      bad = [{ name: 'Bonus', component_type: 'volume_bonus', applies_to_role: 'primary_salesperson' },
             { name: 'Pct', component_type: 'percent_of_gross', applies_to_role: 'sales_manager', rate: 10 }]
      _, error, text = call_tool(token, 'create_commission_plan_draft', name: 'Broken', components: bad)

      expect(error).to be(true)
      expect(text).to include('nothing was saved', 'component 1 (Bonus): Flat amount', 'Units threshold',
                              'component 2 (Pct): Gross type')
      expect(company.commission_plans.count).to eq(0)
      expect(company.commission_components.count).to eq(0)
    end

    it 'refuses a rate over 100% and dashes in names' do
      _, error, text = call_tool(token, 'create_commission_plan_draft', name: 'X',
                                 components: [components.first.merge(rate: 250)])
      expect(error).to be(true)
      expect(text).to include('more than 100%')

      _, error, text = call_tool(token, 'create_commission_plan_draft', name: 'Plan — new', components: components)
      expect(error).to be(true)
      expect(text).to include('em dashes')
    end

    it 'edits a draft by replacing its components, but not an active plan or one deals use' do
      call_tool(token, 'create_commission_plan_draft', name: 'Draft', components: components)
      plan = company.commission_plans.find_by!(name: 'Draft')

      result, error, text = call_tool(token, 'update_commission_plan_draft', id: "commission_plan:#{plan.id}",
                                      description: 'Simpler', components: [components.first.merge(rate: 30)])
      expect(error).to be_falsey, text
      expect(plan.reload.description).to eq('Simpler')
      expect(plan.commission_components.map { |c| c.rate.to_f }).to eq([0.3])
      expect(result['updated']['components'].size).to eq(1)

      active = plan!(name: 'Live')
      _, error, text = call_tool(token, 'update_commission_plan_draft', id: "commission_plan:#{active.id}", name: 'Changed')
      expect(error).to be(true)
      expect(text).to include('active')

      company.deals.create!(name: 'Uses it', stage: 'proposal', contact_id: buyer.id, commission_plan_id: plan.id)
      _, error, text = call_tool(token, 'update_commission_plan_draft', id: "commission_plan:#{plan.id}", name: 'Again')
      expect(error).to be(true)
      expect(text).to include('Deals already use')
    end

    it 'needs component create permission to build components' do
      limited = connect!(connector_user(company, { 'commission_plans' => %w[read create] }))['access_token']
      _, error, = call_tool(limited, 'create_commission_plan_draft', name: 'No comps', components: components)
      expect(error).to be(true)
    end
  end

  describe 'simulating' do
    let(:scenario) do
      { label: 'Average single', front_gross: 12_000, pack: 1_000, back_gross: 1_500, addon_gross: 3_000 }
    end

    it 'tests an unsaved design without saving anything' do
      result, error, text = call_tool(token, 'simulate_commission_plan', components: components, scenarios: [scenario])
      expect(error).to be_falsey, text

      payouts = result['scenarios'].first['payouts'].index_by { |p| p['role'] }
      # 25% of (12,000 - 1,000) + 10% of 3,000 add-ons
      expect(payouts['primary_salesperson']['total']).to eq(3050.0)
      # 5% of total gross 13,500
      expect(payouts['sales_manager']['total']).to eq(675.0)
      expect(result['plan']).to eq('unsaved design')
      expect(company.commission_plans.count).to eq(0)
      expect(company.commission_components.count).to eq(0)
    end

    it 'pays a volume bonus once, on the unit that reaches the threshold, only on the deal kind it names' do
      bonus = { name: 'Five a month', component_type: 'volume_bonus', flat_amount: 500, units_threshold: 5,
                threshold_period: 'monthly', applies_to_role: 'primary_salesperson', deal_type: 'new' }
      scenarios = [scenario.merge(label: 'first', deal_type: 'new', units_this_period: 1),
                   scenario.merge(label: 'fifth', deal_type: 'new', units_this_period: 5),
                   scenario.merge(label: 'sixth', deal_type: 'new', units_this_period: 6),
                   scenario.merge(label: 'fifth used', deal_type: 'used', units_this_period: 5)]
      result, error, text = call_tool(token, 'simulate_commission_plan', components: [bonus], scenarios: scenarios)
      expect(error).to be_falsey, text

      totals = result['scenarios'].to_h { |s| [s['label'], s['payouts'].first&.dig('total') || 0.0] }
      expect(totals).to eq('first' => 0.0, 'fifth' => 500.0, 'sixth' => 0.0, 'fifth used' => 0.0)
      expect(result['warnings'].join(' ')).to include('limited to new deals')
    end

    it 'splits the primary components 50/50 on a shared deal, odd cent to the primary' do
      plan_parts = [{ name: 'Front', component_type: 'percent_of_gross', gross_type: 'front', rate: 25,
                      applies_to_role: 'primary_salesperson' }]
      result, = call_tool(token, 'simulate_commission_plan', components: plan_parts,
                                                             scenarios: [{ front_gross: 1000.12, split_with_secondary: true }])
      payouts = result['scenarios'].first['payouts'].to_h { |p| [p['role'], p['total']] }
      # 25% of 1,000.12 is 250.03
      expect(payouts).to eq('primary_salesperson' => 125.02, 'secondary_salesperson' => 125.01)
    end

    # Found from Claude Desktop on staging: a split deal halved the front
    # line but paid the bonus in full with nothing saying why.
    it 'says a volume bonus on a split deal was not split, and warns that the plan splits the primary' do
      plan_parts = [{ name: 'Front', component_type: 'percent_of_gross', gross_type: 'commissionable_front', rate: 25,
                      applies_to_role: 'primary_salesperson' },
                    { name: 'Five a month', component_type: 'volume_bonus', flat_amount: 500, units_threshold: 5,
                      threshold_period: 'monthly', applies_to_role: 'primary_salesperson' }]
      result, error, text = call_tool(token, 'simulate_commission_plan', components: plan_parts, scenarios: [
        scenario.merge(label: 'Shared fifth', split_with_secondary: true, units_this_period: 5)
      ])
      expect(error).to be_falsey, text

      payouts = result['scenarios'].first['payouts'].index_by { |p| p['role'] }
      bonus = payouts['primary_salesperson']['components'].find { |c| c['component'] == 'Five a month' }
      expect(bonus['amount']).to eq(500.0)
      expect(bonus['note']).to include('not split; volume bonuses pay in full to the person who reached the threshold')
      expect(payouts['secondary_salesperson']['components'].map { |c| c['component'] }).to eq(['Front'])

      warning = result['warnings'].find { |w| w.include?('no secondary_salesperson component') }
      expect(warning).to include('Shared fifth', '(Front)', 'split 50/50', 'Volume bonuses are not split')
      expect(result['warnings'].join(' ')).not_to match(/[–—]/)
    end

    it 'gives no split warning when the plan pays the secondary on its own terms' do
      plan_parts = [{ name: 'Front', component_type: 'percent_of_gross', gross_type: 'commissionable_front', rate: 25,
                      applies_to_role: 'primary_salesperson' },
                    { name: 'Second', component_type: 'flat_per_unit', flat_amount: 100,
                      applies_to_role: 'secondary_salesperson' }]
      result, = call_tool(token, 'simulate_commission_plan', components: plan_parts,
                                                             scenarios: [scenario.merge(split_with_secondary: true)])
      expect(result['warnings'].join(' ')).not_to include('no secondary_salesperson component')
    end

    it 'says which gross each line used and what the pack took off' do
      plan_parts = [{ name: 'After pack', component_type: 'percent_of_gross', gross_type: 'commissionable_front', rate: 25,
                      applies_to_role: 'primary_salesperson' },
                    { name: 'Before pack', component_type: 'percent_of_gross', gross_type: 'front', rate: 10,
                      applies_to_role: 'sales_manager' },
                    { name: 'Per home', component_type: 'flat_per_unit', flat_amount: 300,
                      applies_to_role: 'primary_salesperson' }]
      result, error, text = call_tool(token, 'simulate_commission_plan', components: plan_parts, scenarios: [scenario])
      expect(error).to be_falsey, text

      run = result['scenarios'].first
      expect(run['figures_used']).to include('front_gross' => 12_000.0, 'commissionable_front_gross' => 11_000.0,
                                             'pack_taken_off' => 1_000.0)
      lines = run['payouts'].flat_map { |p| p['components'] }.index_by { |c| c['component'] }
      expect(lines['After pack']['based_on']).to include('gross_type' => 'commissionable_front', 'amount' => 11_000.0,
                                                         'pack_taken_off' => 1_000.0)
      expect(lines['After pack']['based_on']['worked_out']).to eq('$12,000.00 front gross less $1,000.00 pack is $11,000.00')
      expect(lines['Before pack']['based_on']).to include('gross_type' => 'front', 'amount' => 12_000.0)
      expect(lines['Before pack']['based_on']['worked_out']).to include('before pack')
      expect(lines['Per home']).not_to have_key('based_on')
      expect(result['warnings'].join(' ')).to include('Before pack: pays on front gross before pack')

      no_pack, = call_tool(token, 'simulate_commission_plan', components: plan_parts,
                                                              scenarios: [scenario.merge(pack: 0)])
      expect(no_pack['scenarios'].first['figures_used']).not_to have_key('pack_taken_off')
      expect(no_pack['warnings'].join(' ')).not_to include('pays on front gross before pack')
    end

    it 'tells Claude what "front gross" usually means' do
      tools = mcp_post(token, 'tools/list').dig('result', 'tools').index_by { |t| t['name'] }
      gross = tools['create_commission_plan_draft'].dig('inputSchema', 'properties', 'components', 'items',
                                                        'properties', 'gross_type', 'description')
      expect(gross).to include('front gross after pack', 'use commissionable_front')
      expect(tools.values.map { |t| t['description'] }.join).not_to match(/[–—]/)
    end

    it 'matches what the payment engine computes for a real deal with the same figures' do
      plan = plan!(name: 'Engine check')
      company.commission_components.create!(name: 'Mgr', component_type: 'percent_of_gross', gross_type: 'back',
                                            rate: 0.1, applies_to_role: 'sales_manager', commission_plan: plan,
                                            is_active: true, sequence: 2)
      company.commission_components.create!(name: 'Flat', component_type: 'flat_per_unit', flat_amount: 250,
                                            applies_to_role: 'all_participants', commission_plan: plan,
                                            is_active: true, sequence: 3)
      rep = connector_user(company)
      manager = connector_user(company)
      deal = company.deals.create!(name: 'Real', stage: 'proposal', contact_id: buyer.id, selling_price: 120_000, unit_cost: 80_000,
                                   finance_reserve: 900, product_margin: 600, commission_plan_id: plan.id,
                                   owner_id: rep.id, sales_manager_id: manager.id)
      engine = CommissionPaymentGeneratorService.preview_for_deal(deal)[:participants]
                                                .to_h { |p| [p[:role], p[:estimated_amount].to_f] }

      figures = { front_gross: deal.front_gross, commissionable_front_gross: deal.commissionable_front_gross,
                  back_gross: deal.back_gross, total_gross: deal.total_gross, addon_gross: deal.addon_gross,
                  selling_price: deal.selling_price }.transform_values { |v| v&.to_f }.compact
      result, error, text = call_tool(token, 'simulate_commission_plan', plan_id: "commission_plan:#{plan.id}",
                                                                        scenarios: [figures])
      expect(error).to be_falsey, text
      simulated = result['scenarios'].first['payouts'].to_h { |p| [p['role'], p['total']] }

      expect(engine.keys).to contain_exactly('primary_salesperson', 'sales_manager')
      engine.each { |role, amount| expect(simulated[role]).to eq(amount), role }
    end
  end

  describe 'undo' do
    let(:admin) { connector_user(company, grants, role: 'admin') }

    def undo_last
      change = McpChange.order(:id).last
      McpTools::Undo.undo!(change, by: admin)
    end

    it 'deletes a draft it created, components and all, while untouched' do
      call_tool(token, 'create_commission_plan_draft', name: 'Undo me', components: components)
      expect(McpTools::Undo.describe(McpChange.order(:id).last)).to include('draft commission plan')

      expect(undo_last).to be_undone
      expect(company.commission_plans.count).to eq(0)
      expect(company.commission_components.count).to eq(0)
    end

    it 'leaves a draft someone activated since' do
      call_tool(token, 'create_commission_plan_draft', name: 'Kept', components: components)
      company.commission_plans.find_by!(name: 'Kept').update!(is_active: true)

      result = undo_last
      expect(result).not_to be_undone
      expect(result.message).to include('activated')
    end

    it 'restores a draft to how it was before an edit' do
      call_tool(token, 'create_commission_plan_draft', name: 'Before', components: components)
      plan = company.commission_plans.find_by!(name: 'Before')
      call_tool(token, 'update_commission_plan_draft', id: "commission_plan:#{plan.id}", name: 'After',
                                                       components: [components.first])

      expect(undo_last).to be_undone
      expect(plan.reload.name).to eq('Before')
      expect(plan.commission_components.ordered.map(&:name)).to eq(['Front', 'Manager override', 'Add-ons'])
    end
  end
end
