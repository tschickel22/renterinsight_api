# frozen_string_literal: true

require 'rails_helper'
require_relative '../../support/mcp_connector_helpers'

# "Let AI apps see dealer cost and gross" covers the accounting tools too.
# Off (the default): cost of goods sold, gross profit and net income stay out
# of the accounting summary and the budget tools, and bills for homes and
# jobs show no amounts. On: the books as the person's role reads them.
# Also: a daily record limit of 0 pauses every read tool, single record
# lookups included, as the AI Apps tab says.
RSpec.describe 'MCP dealer cost switch and read limit', :mcp, type: :request do
  before do
    seed_rbac!
    TenantModuleOverride.create!(company_id: company.id, module_key: 'finance.accounting', is_enabled: true)
  end

  let(:company) { connector_company }
  let(:denver) { company.locations.create!(name: 'Denver', timezone: 'America/Denver') }
  let(:grants) do
    { 'bills' => %w[read], 'financial_reports' => %w[read], 'budgets' => %w[read], 'leads' => %w[read],
      'deals' => %w[read] }
  end
  let(:user) { connector_user(company, grants) }
  let(:token) { connect!(user)['access_token'] }

  def gl!(number, name, type, sub_type)
    company.chart_of_accounts.create!(account_number: number, name: name, account_type: type, sub_type: sub_type,
                                      normal_balance: %w[asset expense].include?(type) ? 'debit' : 'credit',
                                      is_active: true, is_header: false)
  end

  let!(:cash) { gl!('T1991', 'Operating Checking', 'asset', 'bank') }
  let!(:inventory) { gl!('T1300', 'Home Inventory', 'asset', 'inventory') }
  let!(:sales) { gl!('T4991', 'Home Sales', 'revenue', 'sales_revenue') }
  let!(:cogs) { gl!('T5000', 'Cost of Homes Sold', 'expense', 'cost_of_goods_sold') }
  let!(:ads) { gl!('T6100', 'Advertising', 'expense', 'operating_expense') }

  def post!(debit, credit, amount, date = Date.current)
    Accounting::ManualPostingService.new(company).post_simple!(debit_account: debit, credit_account: credit,
                                                               amount: amount, memo: 'test', entry_date: date)
  end

  def bill!(vendor, amount, account)
    company.bills.create!(vendor_name: vendor, bill_date: Date.current - 5, due_date: Date.current + 5,
                          status: 'pending', location: denver,
                          bill_line_items_attributes: [{ chart_of_account_id: account.id, amount: amount }])
  end

  def allow_costs!
    Setting.set('Company', company.id, 'mcp_settings', { 'show_costs' => true })
  end

  describe 'accounting_summary' do
    before do
      post!(cash, sales, 100_000)
      post!(cogs, cash, 78_000)
      post!(ads, cash, 2_000)
    end

    it 'leaves out cost of goods sold and gross profit but keeps net income while the switch is off' do
      summary, error, text = call_tool(token, 'accounting_summary')
      expect(error).to be_falsey, text
      period = summary.dig('profit_and_loss', 'period')
      expect(period).to include('revenue' => 100_000.0, 'expenses' => 2_000.0)
      expect(period.keys).not_to include('cost_of_goods_sold', 'gross_profit')
      expect(period['net_income']).to eq(20_000.0)
      expect(period['costs_hidden']).to include('Let AI apps see dealer cost and gross')
      expect(summary.dig('profit_and_loss', 'fiscal_year_to_date').keys).not_to include('cost_of_goods_sold')
      expect(text).not_to include('78000')
    end

    it 'gives the full P&L once the dealer allows dealer cost' do
      allow_costs!
      summary, = call_tool(token, 'accounting_summary')
      expect(summary.dig('profit_and_loss', 'period')).to include('cost_of_goods_sold' => 78_000.0,
                                                                  'gross_profit' => 22_000.0, 'net_income' => 20_000.0)
      expect(summary.dig('profit_and_loss', 'period')).not_to have_key('costs_hidden')
    end
  end

  describe 'bills' do
    let!(:home_bill) { bill!('Champion Homes', 61_500, inventory) }
    let!(:ad_bill) { bill!('Facebook Ads', 400, ads) }

    it 'hides the amounts of bills for homes and jobs, and leaves them out of the totals' do
      result, error, text = call_tool(token, 'list_bills')
      expect(error).to be_falsey, text
      home = result['items'].find { |i| i['id'] == "bill:#{home_bill.id}" }
      ad = result['items'].find { |i| i['id'] == "bill:#{ad_bill.id}" }
      expect(home).to include('vendor' => 'Champion Homes', 'amounts_hidden' => 'dealer cost')
      expect(home.keys).not_to include('total', 'paid', 'balance_due')
      expect(ad).to include('total' => 400.0, 'balance_due' => 400.0)
      expect(result['totals']).to include('bills' => 2, 'balance_due' => 400.0, 'amounts_hidden' => 1)
      expect(text).not_to include('61500')

      summary, = call_tool(token, 'accounting_summary')
      expect(summary['bills']).to include('unpaid' => 2, 'balance_due' => 400.0, 'amounts_hidden' => 1)
      expect(summary['bills']['note']).to include('homes and jobs')
    end

    it 'hides a bill with a line tied to a project too (job cost)' do
      ad_bill.bill_line_items.first.update_columns(project_id: 1) # any project link marks job cost
      result, = call_tool(token, 'list_bills')
      expect(result['items'].find { |i| i['id'] == "bill:#{ad_bill.id}" }).to have_key('amounts_hidden')
    end

    it 'shows every amount once the dealer allows dealer cost' do
      allow_costs!
      result, = call_tool(token, 'list_bills')
      expect(result['items'].find { |i| i['id'] == "bill:#{home_bill.id}" }).to include('total' => 61_500.0)
      expect(result['totals']).to include('balance_due' => 61_900.0)
      expect(result['totals']).not_to have_key('amounts_hidden')
    end
  end

  describe 'budget tools' do
    let(:year) { Date.current.year }
    let!(:budget) do
      company.budgets.create!(name: 'Plan', fiscal_year: year, budget_type: 'annual', status: 'active',
                              consolidation_type: 'standalone').tap do |b|
        { sales => 10_000, cogs => 7_000, ads => 100 }.each do |account, monthly|
          line = b.budget_lines.build(chart_of_account: account)
          (1..12).each { |m| line.set_month_amount(m, monthly) }
          line.save!
        end
      end
    end

    before do
      post!(cash, sales, 9_000)
      post!(cogs, cash, 6_500)
      post!(ads, cash, 300)
      post!(cash, sales, 5_000, Date.new(year - 1, 3, 10))
      post!(cogs, cash, 3_900, Date.new(year - 1, 3, 10))
    end

    it 'budget_variance leaves out cost of goods sold rows, keeps net income, and works the subtotal without them' do
      result, error, text = call_tool(token, 'budget_variance', period: 'ytd')
      expect(error).to be_falsey, text
      expect(result['rows'].map { |r| r['account_name'] }).not_to include('Cost of Homes Sold')
      expect(result['net_income']).to be_present
      expect(result['costs_hidden']).to include('cost of goods sold')
      expect(result.dig('subtotals', 'expense', 'actual')).to eq(300.0)
      expect(text).not_to include('6500')
    end

    it 'budget_history leaves out cost of goods sold and keeps net income' do
      result, = call_tool(token, 'budget_history')
      expect(result['groups'].map { |g| g['group'] }).to eq(%w[revenue])
      expect(result).to have_key('net_income')
      expect(result['costs_hidden']).to be_present
    end

    it 'both give the full picture once the dealer allows dealer cost' do
      allow_costs!
      variance, = call_tool(token, 'budget_variance', period: 'ytd')
      expect(variance['rows'].map { |r| r['account_name'] }).to include('Cost of Homes Sold')
      expect(variance['net_income']).to be_present
      history, = call_tool(token, 'budget_history')
      expect(history['groups'].map { |g| g['group'] }).to include('cost_of_goods_sold')
      expect(history['net_income']).to be_present
    end
  end

  describe 'guidance' do
    def instructions
      mcp_post(token, 'initialize', { protocolVersion: '2025-06-18', capabilities: {}, clientInfo: { name: 'c', version: '1' } })
        .dig('result', 'instructions')
    end

    it 'says what the switch really covers, and that journal entries and bank lines keep their amounts' do
      expect(instructions).to include('amounts_hidden', 'Journal entries and bank feed lines')
      expect(instructions).not_to include('not available through this connector')
      allow_costs!
      expect(instructions).to include('cost of goods sold, net income and the amounts on bills for homes and jobs')
    end
  end

  describe 'records read per day at 0' do
    it 'pauses every read tool, single record lookups included, and says it is per person' do
      lead = company.leads.create!(first_name: 'Ana', last_name: 'Diaz', email: 'ana@example.com', status: 'new')
      Setting.set('Company', company.id, 'mcp_settings', { 'daily_record_limit' => 0 })

      tools = mcp_post(token, 'tools/list').dig('result', 'tools')
      read_tools = tools.select { |t| t.dig('annotations', 'readOnlyHint') }
      expect(read_tools.map { |t| t['name'] }).to include('fetch', 'pipeline_summary', 'budget_variance', 'get_workflow',
                                                          'get_campaign', 'get_commission_plan')

      args = { 'fetch' => { id: "lead:#{lead.id}" },
               'simulate_commission_plan' => { plan_id: 'commission_plan:1', scenarios: [{ name: 'a', front_gross: 1000 }] } }
      read_tools.each do |tool|
        required = Array(tool.dig('inputSchema', 'required'))
        given = args[tool['name']] || required.to_h do |key|
          type = tool.dig('inputSchema', 'properties', key, 'type')
          [key, type == 'array' ? [] : 'x:1']
        end
        _, error, text = call_tool(token, tool['name'], given)
        expect(error).to be(true), "#{tool['name']} ran with a limit of 0: #{text}"
        expect(text).to include('Daily limit of 0 records', 'for this person, across all their AI apps')
      end
    end
  end
end
