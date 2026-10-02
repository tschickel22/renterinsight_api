# frozen_string_literal: true

require 'rails_helper'
require_relative '../../support/mcp_connector_helpers'

# Budgets through the connector. The rule: read what the person could read
# in the app, build and change DRAFTS only, and leave activating, locking and
# approving to a person in DealerTide.
RSpec.describe 'MCP budget tools', :mcp, type: :request do
  before do
    seed_rbac!
    TenantModuleOverride.create!(company_id: company.id, module_key: 'finance.accounting', is_enabled: true)
  end

  let(:company) { connector_company }
  let(:denver) { company.locations.create!(name: 'Denver', timezone: 'America/Denver') }
  let(:boulder) { company.locations.create!(name: 'Boulder', timezone: 'America/Denver') }
  let(:user) { connector_user(company, { 'budgets' => %w[read create update] }) }
  let(:token) { connect!(user)['access_token'] }
  let(:year) { Date.current.year }

  def account!(number, name, type, sub_type: nil, header: false, owner: company)
    owner.chart_of_accounts.create!(account_number: number, name: name, account_type: type, sub_type: sub_type,
                                    normal_balance: %w[asset expense].include?(type) ? 'debit' : 'credit',
                                    is_header: header, is_active: true)
  end

  let!(:bank) { account!('T1000', 'Operating Bank', 'asset', sub_type: 'bank') }
  let!(:sales) { account!('T4000', 'Home Sales', 'revenue', sub_type: 'sales_revenue') }
  let!(:cogs) { account!('T5000', 'Cost of Homes Sold', 'expense', sub_type: 'cost_of_goods_sold') }
  let!(:ads) { account!('T6100', 'Advertising', 'expense', sub_type: 'operating_expense') }

  def budget!(attrs = {}, lines = {})
    company.budgets.create!({ name: "B-#{SecureRandom.hex(2)}", fiscal_year: year, budget_type: 'annual',
                              status: 'draft', consolidation_type: 'standalone' }.merge(attrs)).tap do |b|
      lines.each do |account, monthly|
        line = b.budget_lines.build(chart_of_account: account)
        (1..12).each { |m| line.set_month_amount(m, monthly) }
        line.save!
      end
    end
  end

  def post!(debit, credit, amount, date = Date.current, location_id: nil)
    Accounting::ManualPostingService.new(company).post_simple!(debit_account: debit, credit_account: credit,
                                                               amount: amount, memo: 'test', entry_date: date,
                                                               location_id: location_id)
  end

  def gid(account)
    "gl_account:#{account.id}"
  end

  describe 'gating' do
    it 'refuses when Accounting is not on the plan' do
      TenantModuleOverride.where(company_id: company.id, module_key: 'finance.accounting').delete_all
      Rails.cache.clear
      _, error, text = call_tool(token, 'list_budgets')
      expect(error).to be(true)
      expect(text).to include("not part of this account's plan")
    end

    it 'refuses a role without the budgets permission' do
      other = connector_user(company, { 'leads' => %w[read] })
      _, error, text = call_tool(connect!(other)['access_token'], 'list_budgets')
      expect(error).to be(true)
      expect(text).to include('does not allow read on budgets')
    end

    it 'hides the write tools from a read-only connection and offers no activate or lock tool' do
      read_only = connect!(user, allow_write: false)['access_token']
      names = mcp_post(read_only, 'tools/list').dig('result', 'tools').map { |t| t['name'] }
      expect(names).to include('list_budgets', 'get_budget', 'budget_variance', 'budget_history')
      expect(names).not_to include('create_budget_draft', 'update_budget_draft')

      all = mcp_post(token, 'tools/list').dig('result', 'tools').map { |t| t['name'] }
      expect(all.grep(/budget/).grep(/activate|lock|approve|delete|archive/)).to be_empty
    end

    it 'lists the budget prompts with no dashes in them' do
      prompts = mcp_post(token, 'prompts/list').dig('result', 'prompts').map { |p| p['name'] }
      expect(prompts).to include('budget_check', 'budget_from_last_year')
      %w[budget_check budget_from_last_year].each do |name|
        text = mcp_post(token, 'prompts/get', { name: name, arguments: { growth_percent: '5' } })
               .dig('result', 'messages', 0, 'content', 'text')
        expect(text).not_to match(/[–—]/)
      end
    end
  end

  describe 'reading' do
    it 'shows a budget grouped into a P&L with net income' do
      budget = budget!({}, sales => 10_000, cogs => 7_000, ads => 500)
      doc, = call_tool(token, 'get_budget', id: "budget:#{budget.id}")

      expect(doc['groups'].map { |g| g['group'] }).to eq(%w[revenue cost_of_goods_sold expense])
      expect(doc['net_income']['annual']).to eq((10_000 - 7_000 - 500) * 12.0)
      expect(doc['month_labels'].first).to eq("Jan #{year}")
      expect(doc['editable_here']).to be(true)
      expect(doc['url']).to end_with("/accounting/budgets/#{budget.id}")
    end

    it 'totals a budget as revenue, costs and net income, not one sum of every line' do
      budget = budget!({}, sales => 10_000, cogs => 7_000, ads => 500)
      listed = call_tool(token, 'list_budgets', fiscal_year: year).first['items'].find { |b| b['id'] == "budget:#{budget.id}" }
      expect(listed).not_to have_key('total_budgeted')
      expect(listed['totals']).to eq('revenue' => 120_000.0, 'cost_of_goods_sold' => 84_000.0, 'expense' => 6_000.0,
                                     'net_income' => 30_000.0)
    end

    it "never reaches another company's budget" do
      other = Company.create!(name: 'Other', industry: 'manufactured_housing')
      theirs = other.budgets.create!(name: 'Theirs', fiscal_year: year, budget_type: 'annual', status: 'draft',
                                     consolidation_type: 'standalone')
      _, error, text = call_tool(token, 'get_budget', id: "budget:#{theirs.id}")
      expect(error).to be(true)
      expect(text).to include('No record')
    end

    it 'shows a location user their locations and company-wide budgets only' do
      local = connector_user(company, { 'budgets' => %w[read] }, location: denver)
      mine = budget!(location_id: denver.id)
      wide = budget!
      budget!(location_id: boulder.id)

      result, = call_tool(connect!(local)['access_token'], 'list_budgets')
      expect(result['items'].map { |i| i['id'] }).to contain_exactly("budget:#{mine.id}", "budget:#{wide.id}")
    end

    it 'compares with the posted books exactly as the Budget vs Actual report does' do
      budget = budget!({ status: 'active' }, sales => 2_000, ads => 10)
      post!(bank, sales, 1_500)
      post!(ads, bank, 400)

      result, = call_tool(token, 'budget_variance', period: 'ytd')
      expected = BudgetService.calculate_variance(budget.reload, period: 'ytd')

      expect(result['budget']['id']).to eq("budget:#{budget.id}")
      expect(result['net_income']['actual']).to eq(expected[:net_income][:actual_amount].to_f)
      expect(result['net_income']['budget']).to eq(expected[:net_income][:budget_amount].to_f)
      expect(result['biggest_misses'].map { |r| r['account_name'] }).to include('Advertising')

      month, = call_tool(token, 'budget_variance', id: "budget:#{budget.id}", period: 'month',
                                                   month: Date.current.strftime('%Y-%m'))
      sales_row = month['rows'].find { |r| r['account_name'] == 'Home Sales' }
      expect(sales_row).to include('budget' => 2_000.0, 'actual' => 1_500.0, 'impact' => -500.0)
    end

    it "compares a location budget with that location's books only" do
      budget = budget!({ location_id: denver.id, status: 'active' }, sales => 1_000)
      post!(bank, sales, 400, location_id: denver.id)
      post!(bank, sales, 250, location_id: boulder.id)
      post!(bank, sales, 100) # no location: company level only

      result, error, text = call_tool(token, 'budget_variance', id: "budget:#{budget.id}", period: 'month',
                                                                month: Date.current.strftime('%Y-%m'))
      expect(error).to be_falsey, text
      sales_row = result['rows'].find { |r| r['account_name'] == 'Home Sales' }
      expect(sales_row['actual']).to eq(400.0)

      coverage = BudgetService.data_coverage(company, budget.fiscal_year, location_id: denver.id)
      expect(coverage[:has_data]).to be(true)
      expect(coverage[:unlocated_lines]).to eq(2)
      expect(BudgetService.data_coverage(company, budget.fiscal_year, location_id: boulder.id + 999)[:has_data]).to be(false)
    end

    it "gives last year's actuals by month and says how much history there is" do
      post!(bank, sales, 900, Date.new(year - 1, 3, 15))
      result, = call_tool(token, 'budget_history')

      expect(result['fiscal_year']).to eq(year - 1)
      expect(result['coverage']['coverage_count']).to eq(1)
      expect(result['note']).to include('Only 1 of 12 months')
      line = result['groups'].first['lines'].first
      expect(line['gl_account_id']).to eq(gid(sales))
      expect(line['months'][2]).to eq(900.0)
      expect(result['groups'].flat_map { |g| g['lines'] }.map { |l| l['account_number'] }).not_to include('T1000')
    end
  end

  describe 'drafting' do
    it 'creates a draft from lines, spreading an annual figure to the cent' do
      result, error, text = call_tool(token, 'create_budget_draft', fiscal_year: year + 1, name: 'Plan', lines: [
        { gl_account_id: gid(sales), annual: 1_000, seasonality: [1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1] },
        { gl_account_id: gid(ads), months: Array.new(12, 50) }
      ])
      expect(error).to be_falsey, text

      budget = company.budgets.find_by!(name: 'Plan')
      expect(budget.status).to eq('draft')
      expect(budget.created_by_id).to eq(user.id)
      line = budget.budget_lines.find_by!(chart_of_account: sales)
      expect(line.annual_total).to eq(1_000)
      expect(line.month_1).to eq(83.33)
      expect(line.month_12).to eq(83.37)
      expect(result['draft']['net_income']['annual']).to eq(400.0)
      expect(result['next_step']).to include('DRAFT', 'Activate')
    end

    it 'refuses balance sheet, header, duplicate and foreign accounts' do
      header = account!('T6000', 'Operating Expenses', 'expense', header: true)
      other = Company.create!(name: 'Other', industry: 'manufactured_housing')
      foreign = account!('T4000', 'Theirs', 'revenue', owner: other)

      { [{ gl_account_id: gid(bank), annual: 1 }] => 'asset account',
        [{ gl_account_id: gid(header), annual: 1 }] => 'header',
        [{ gl_account_id: gid(ads), annual: 1 }, { gl_account_id: gid(ads), annual: 2 }] => 'listed twice',
        [{ gl_account_id: gid(foreign), annual: 1 }] => 'No account',
        [{ gl_account_id: gid(ads), months: [1, 2] }] => '12' }.each do |lines, message|
        _, error, text = call_tool(token, 'create_budget_draft', fiscal_year: year, lines: lines)
        expect(error).to be(true)
        expect(text).to include(message)
      end
      expect(company.budgets.count).to eq(0)
    end

    it "copies a prior year's budget with growth" do
      budget!({ fiscal_year: year, location_id: nil, status: 'active' }, sales => 1_000)
      result, = call_tool(token, 'create_budget_draft', fiscal_year: year + 1, copy_from_fiscal_year: year,
                                                        growth_percent: 10)

      copy = company.budgets.find_by!(fiscal_year: year + 1)
      expect(copy.status).to eq('draft')
      expect(copy.budget_lines.first.month_1).to eq(1_100)
      expect(result['source']).to start_with('budget:')
    end

    # Found from Claude Desktop on staging: a year whose only entry was a
    # transfer between two bank accounts was copied as a "budget" of those
    # two cash accounts.
    it 'refuses to copy a year with no revenue or expense activity and saves nothing' do
      savings = account!('T1030', 'Savings / Reserve', 'asset', sub_type: 'bank')
      post!(bank, savings, 12_000, Date.new(year - 1, 4, 10))

      _, error, text = call_tool(token, 'create_budget_draft', fiscal_year: year, copy_from_fiscal_year: year - 1,
                                                               growth_percent: 5)
      expect(error).to be(true)
      expect(text).to include("No revenue or expense activity in fiscal year #{year - 1}", 'nothing was saved')
      expect(text).not_to match(/[–—]/)
      expect(company.budgets.count).to eq(0)

      history, = call_tool(token, 'budget_history', fiscal_year: year - 1)
      expect(history['has_pl_history']).to be(false)
      expect(history['note']).to include('only balance sheet accounts')
    end

    it 'copies only revenue and expense accounts from actuals, annualizing a partial year' do
      savings = account!('T1030', 'Savings / Reserve', 'asset', sub_type: 'bank')
      post!(bank, sales, 900, Date.new(year - 1, 3, 15))
      post!(bank, savings, 12_000, Date.new(year - 1, 6, 10))

      result, error, text = call_tool(token, 'create_budget_draft', fiscal_year: year, copy_from_fiscal_year: year - 1,
                                                                     growth_percent: 10)
      expect(error).to be_falsey, text
      copy = company.budgets.find_by!(fiscal_year: year)
      expect(copy.budget_lines.pluck(:chart_of_account_id)).to eq([sales.id])
      expect(copy.budget_lines.first.month_1).to eq(990)
      expect(copy.metadata).to include('source_label' => 'actuals_annualized', 'created_via' => 'ai_connector')
      expect(result['source']).to eq('actuals_annualized')
    end

    it "leaves balance sheet lines out when copying a prior year's budget" do
      budget!({ fiscal_year: year, location_id: nil }, sales => 1_000, bank => 5_000)
      call_tool(token, 'create_budget_draft', fiscal_year: year + 1, copy_from_fiscal_year: year)

      copy = company.budgets.find_by!(fiscal_year: year + 1)
      expect(copy.budget_lines.pluck(:chart_of_account_id)).to eq([sales.id])
    end

    it 'keeps a location user to their own locations' do
      local = connector_user(company, { 'budgets' => %w[read create] }, location: denver)
      local_token = connect!(local)['access_token']

      _, error, text = call_tool(local_token, 'create_budget_draft', fiscal_year: year,
                                                                     lines: [{ gl_account_id: gid(ads), annual: 12 }])
      expect(error).to be(true)
      expect(text).to include('own locations')
      _, error, = call_tool(local_token, 'create_budget_draft', fiscal_year: year, location_id: boulder.id,
                                                                lines: [{ gl_account_id: gid(ads), annual: 12 }])
      expect(error).to be(true)
      _, error, = call_tool(local_token, 'create_budget_draft', fiscal_year: year, location_id: denver.id,
                                                                lines: [{ gl_account_id: gid(ads), annual: 12 }])
      expect(error).to be_falsey
    end

    it 'changes a draft and refuses anything that is not a draft' do
      draft = budget!({}, sales => 100, ads => 10)
      result, error, text = call_tool(token, 'update_budget_draft', id: "budget:#{draft.id}", name: 'Renamed',
                                                                    lines: [{ gl_account_id: gid(sales), annual: 2_400 }],
                                                                    remove_gl_account_ids: [gid(ads)])
      expect(error).to be_falsey, text
      expect(draft.reload.name).to eq('Renamed')
      expect(draft.budget_lines.pluck(:chart_of_account_id)).to eq([sales.id])
      expect(draft.budget_lines.first.month_1).to eq(200)
      expect(result['lines_removed']).to eq(1)

      %w[active locked archived].each do |status|
        other = budget!({ status: status }, sales => 1)
        _, error, text = call_tool(token, 'update_budget_draft', id: "budget:#{other.id}", name: 'X')
        expect(error).to be(true)
        expect(text).to eq('Only draft budgets can be changed here; revert it to draft in DealerTide first.')
      end
    end
  end

  describe 'undo' do
    it 'deletes a draft it created, unless someone has worked on it since' do
      call_tool(token, 'create_budget_draft', fiscal_year: year, name: 'One', lines: [{ gl_account_id: gid(ads), annual: 12 }])
      call_tool(token, 'create_budget_draft', fiscal_year: year, name: 'Two', lines: [{ gl_account_id: gid(ads), annual: 12 }])
      one_change, two_change = McpChange.where(record_type: 'Budget').order(:id).to_a

      company.budgets.find_by!(name: 'Two').update!(status: 'active')
      expect(McpTools::Undo.undo!(one_change, by: user)).to be_undone
      expect(company.budgets.exists?(name: 'One')).to be(false)

      skipped = McpTools::Undo.undo!(two_change, by: user)
      expect(skipped).not_to be_undone
      expect(company.budgets.exists?(name: 'Two')).to be(true)
      expect(McpTools::Undo.describe(one_change)).to include('draft budget')
    end

    it 'puts an edited draft back, unless it was edited again' do
      draft = budget!({ name: 'Orig' }, sales => 100)
      call_tool(token, 'update_budget_draft', id: "budget:#{draft.id}", name: 'New',
                                              lines: [{ gl_account_id: gid(ads), annual: 120 }])
      change = McpChange.where(record_type: 'Budget').last

      expect(McpTools::Undo.undo!(change, by: user)).to be_undone
      draft.reload
      expect(draft.name).to eq('Orig')
      expect(draft.budget_lines.pluck(:chart_of_account_id)).to eq([sales.id])
      expect(draft.budget_lines.first.month_1).to eq(100)

      call_tool(token, 'update_budget_draft', id: "budget:#{draft.id}", name: 'Again')
      again = McpChange.where(record_type: 'Budget').last
      draft.update!(name: 'Person edited')
      expect(McpTools::Undo.undo!(again, by: user)).not_to be_undone
      expect(draft.reload.name).to eq('Person edited')
    end
  end
end
