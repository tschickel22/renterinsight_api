# frozen_string_literal: true

require 'rails_helper'

# Against the recorded QuickBooks company in spec/fixtures/quickbooks/migration.
RSpec.describe Accounting::Adapters::QuickbooksOnlineAdapter do
  let(:company) { Company.create!(name: "C-#{SecureRandom.hex(4)}") }
  let(:client) { Accounting::QboMigration::FixtureClient.new }
  let(:cutover) { Date.new(2026, 9, 30) }

  def adapter(page_size: described_class::PAGE_SIZE)
    described_class.new(company, nil, {}, client: client, page_size: page_size)
  end

  describe 'paging' do
    it 'reads every page until a short one comes back' do
      accounts = adapter(page_size: 10).fetch_accounts

      expect(accounts.size).to eq(42)
      starts = client.queries.map { |q| q[/STARTPOSITION (\d+)/, 1].to_i }
      expect(starts).to eq([1, 11, 21, 31, 41])
      expect(client.queries).to all(include('MAXRESULTS 10'))
    end

    it 'asks for inactive accounts as well as active ones' do
      accounts = adapter.fetch_accounts
      expect(client.queries.first).to include('Active IN (true, false)')
      escrow = accounts.find { |a| a[:external_id] == '10' }
      expect(escrow).to include(is_active: false, account_type: 'asset', qbo_type: 'Other Current Asset')
    end

    it 'stops after one query when the first page is short' do
      adapter.fetch_vendors
      expect(client.queries.size).to eq(1)
    end
  end

  describe 'trial balance' do
    it 'asks for the fiscal year to the cutover, accrual basis' do
      adapter.fetch_trial_balance(cutover)
      name, params = client.reports.last
      expect(name).to eq('TrialBalance')
      expect(params).to eq(start_date: '2026-01-01', end_date: '2026-09-30', accounting_method: 'Accrual')
    end

    it 'parses rows into account id, debit, credit and balance' do
      tb = adapter.fetch_trial_balance(cutover)

      checking = tb[:rows].find { |r| r[:external_id] == '1' }
      expect(checking).to include(debit: BigDecimal('182450.25'), credit: BigDecimal('0'), balance: BigDecimal('182450.25'))
      floor_plan = tb[:rows].find { |r| r[:external_id] == '15' }
      expect(floor_plan[:balance]).to eq(BigDecimal('-1102500'))
      expect(tb[:rows].map { |r| r[:external_id] }).not_to include('3', '24', '30')
      expect(tb[:total_debit]).to eq(tb[:total_credit])
      expect(tb[:rows].sum { |r| r[:balance] }).to eq(0)
    end

    it 'reads nested sections and falls back to summing when there is no grand total' do
      report = {
        'Columns' => { 'Column' => [{ 'ColTitle' => '' }, { 'ColTitle' => 'Debit' }, { 'ColTitle' => 'Credit' }] },
        'Rows' => { 'Row' => [
          { 'type' => 'Section', 'Rows' => { 'Row' => [
            { 'ColData' => [{ 'value' => 'Cash', 'id' => '7' }, { 'value' => '1,250.50' }, { 'value' => '' }] }
          ] } },
          { 'ColData' => [{ 'value' => 'Loan', 'id' => '8' }, { 'value' => '' }, { 'value' => '1250.50' }] }
        ] }
      }
      parsed = described_class.parse_trial_balance(report)
      expect(parsed[:rows].map { |r| [r[:external_id], r[:balance]] }).to eq([['7', BigDecimal('1250.50')], ['8', BigDecimal('-1250.50')]])
      expect(parsed[:total_debit]).to eq(BigDecimal('1250.50'))
    end

    it 'gives the old importer balances as of the date, not CurrentBalance' do
      balances = adapter.fetch_account_balances(cutover).index_by { |b| b[:external_id] }
      expect(balances['1'][:balance]).to eq(BigDecimal('182450.25'))
      expect(balances['15'][:balance]).to eq(BigDecimal('1102500'))
      expect(balances['10'][:balance]).to eq(BigDecimal('5000')) # inactive, still carried
    end
  end

  describe 'open items as of the cutover' do
    it 'adds back payments dated after the cutover and leaves out later invoices' do
      invoices = adapter.fetch_open_invoices(cutover).index_by { |i| i[:external_id] }

      expect(invoices.keys).not_to include('311')
      expect(invoices['309'][:balance]).to eq(BigDecimal('8750')) # paid in full on 10/04
      expect(invoices['310'][:balance]).to eq(BigDecimal('5600')) # 3,000 paid on 10/02
      expect(invoices['302'][:balance]).to eq(BigDecimal('7400')) # paid before cutover stays paid
      expect(invoices.values.sum { |i| i[:balance] }).to eq(BigDecimal('52290.40'))
    end

    it 'does the same for bills and reads vendor credits' do
      bills = adapter.fetch_open_bills(cutover)
      expect(bills.sum { |b| b[:balance] }).to eq(BigDecimal('14002.11'))
      expect(bills.find { |b| b[:external_id] == '506' }[:balance]).to eq(BigDecimal('1850'))
      expect(bills.find { |b| b[:external_id] == '505' }[:expense_account_external_id]).to eq('38')

      credits = adapter.fetch_open_vendor_credits(cutover)
      expect(credits.map { |c| [c[:vendor_external_id], c[:balance]] }).to eq([['201', BigDecimal('500')]])
    end
  end

  describe 'uncleared items' do
    it 'reads the TransactionList filtered to uncleared, grouped by account' do
      items = adapter.fetch_uncleared_items(cutover)
      _name, params = client.reports.last
      expect(params).to include(cleared: 'Uncleared', end_date: '2026-09-30')

      chase = items['Chase Operating Checking']
      expect(chase.map { |i| [i[:kind], i[:amount], i[:reference]] })
        .to eq([['check', BigDecimal('1200'), '4471'], ['check', BigDecimal('850'), '4473'], ['deposit', BigDecimal('3200'), nil]])
      expect(items['Amex Business Card'].first).to include(kind: 'check', amount: BigDecimal('142.17'), payee: 'Home Depot')
    end
  end

  it 'reads the fiscal year start from CompanyInfo' do
    custom = Accounting::QboMigration::FixtureClient.new(overrides: { company_info: { 'CompanyInfo' => { 'FiscalYearStartMonth' => 'July' } } })
    a = described_class.new(company, nil, {}, client: custom)
    expect(a.fiscal_year_start(Date.new(2026, 9, 30))).to eq(Date.new(2026, 7, 1))
    expect(a.fiscal_year_start(Date.new(2026, 3, 31))).to eq(Date.new(2025, 7, 1))
  end
end
