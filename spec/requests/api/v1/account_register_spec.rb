# frozen_string_literal: true

require 'rails_helper'

# The register: one account's posted lines with a running balance, the
# payee, the other side of the entry and whether the bank has seen it.
RSpec.describe 'Api::V1 account register and bank balances', type: :request do
  let(:company) { Company.create!(name: "Reg-#{SecureRandom.hex(4)}") }
  let(:user) do
    User.create!(email: "reg-#{SecureRandom.hex(4)}@example.com", first_name: 'R', last_name: 'G',
                 password: 'Pass1234!', company_id: company.id, role: 'company_admin')
  end
  let(:headers) { { 'Authorization' => "Bearer #{JsonWebToken.encode(user_id: user.id, company_id: company.id)}" } }
  def json = JSON.parse(response.body)

  let(:checking) do
    company.chart_of_accounts.create!(account_number: '1098', name: 'Register Checking', account_type: 'asset',
                                      normal_balance: 'debit', sub_type: 'bank')
  end
  let(:card) do
    company.chart_of_accounts.create!(account_number: '2098', name: 'Register Visa', account_type: 'liability',
                                      normal_balance: 'credit')
  end
  let(:sales) { company.chart_of_accounts.create!(account_number: '4098', name: 'Register Sales', account_type: 'revenue', normal_balance: 'credit') }
  let(:rent) { company.chart_of_accounts.create!(account_number: '6098', name: 'Register Rent', account_type: 'expense', normal_balance: 'debit') }
  let(:fees) { company.chart_of_accounts.create!(account_number: '6099', name: 'Register Fees', account_type: 'expense', normal_balance: 'debit') }

  def entry(date, lines, memo: nil, **attrs)
    je = company.journal_entries.build({ entry_date: date, memo: memo }.merge(attrs))
    lines.each_with_index do |(acct, dr, cr), i|
      je.journal_entry_lines.build(chart_of_account: acct, debit_amount: dr, credit_amount: cr, position: i)
    end
    je.save!
    je
  end

  describe 'GET /api/v1/accounting/register' do
    let!(:opening) { entry(Date.new(2026, 9, 30), [[checking, 1000, 0], [sales, 0, 1000]], memo: 'Opening') }
    let!(:deposit) { entry(Date.new(2026, 10, 5), [[checking, 500, 0], [sales, 0, 500]], memo: 'Deposit') }
    let!(:rent_paid) do
      entry(Date.new(2026, 10, 9), [[checking, 0, 300], [rent, 250, 0], [fees, 50, 0]], memo: 'Rent and fee')
    end
    let!(:voided) do
      entry(Date.new(2026, 10, 10), [[checking, 0, 999], [rent, 999, 0]], memo: 'Mistake').tap { |e| e.update_columns(is_void: true) }
    end

    it 'lists posted lines newest first with the balance after each, the other side and cleared status' do
      company.bank_transactions.create!(bank_account: company.bank_accounts.create!(bank_name: 'Chase', account_type: 'checking',
                                                                                    account_purpose: 'sync_only', chart_of_account: checking),
                                        transaction_date: Date.new(2026, 10, 5), amount: 500, status: 'matched',
                                        matched_journal_entry_id: deposit.id, description: 'DEPOSIT')

      get '/api/v1/accounting/register', params: { account_id: checking.id, start_date: '2026-10-01', end_date: '2026-10-31' }, headers: headers
      expect(response).to have_http_status(:ok), response.body

      expect(json['opening_balance']).to eq(1000.0)
      expect(json['closing_balance']).to eq(1200.0)
      expect(json['rows'].map { |r| r['memo'] }).to eq(['Rent and fee', 'Deposit'])
      rent_row, deposit_row = json['rows']
      expect(rent_row).to include('money_out' => 300.0, 'money_in' => nil, 'balance' => 1200.0, 'status' => nil,
                                  'journal_entry_id' => rent_paid.id)
      expect(rent_row['account']).to include('name' => 'Split')
      expect(deposit_row).to include('money_in' => 500.0, 'balance' => 1500.0, 'status' => 'cleared')
      expect(deposit_row['account']).to include('id' => sales.id, 'name' => '4098 Register Sales')
      expect(json['bank_account']).to include('name' => 'Chase')
    end

    it 'shows a card in what is owed: a charge raises the balance' do
      entry(Date.new(2026, 10, 3), [[card, 0, 80], [rent, 80, 0]], memo: 'Charge')
      entry(Date.new(2026, 10, 20), [[card, 30, 0], [checking, 0, 30]], memo: 'Payment')

      get '/api/v1/accounting/register', params: { account_id: card.id, start_date: '2026-10-01', end_date: '2026-10-31' }, headers: headers
      expect(json['rows'].map { |r| [r['memo'], r['money_in'], r['money_out'], r['balance']] })
        .to eq([['Payment', 30.0, nil, 50.0], ['Charge', nil, 80.0, 80.0]])
    end

    it 'marks lines in a finished reconciliation as reconciled' do
      bank = company.bank_accounts.create!(bank_name: 'Chase', account_type: 'checking', account_purpose: 'sync_only', chart_of_account: checking)
      rec = company.bank_reconciliations.create!(bank_account: bank, statement_date: Date.new(2026, 10, 31), statement_ending_balance: 1500,
                                                 beginning_balance: 1000, status: 'completed')
      line = deposit.journal_entry_lines.find_by(chart_of_account: checking)
      rec.bank_reconciliation_items.create!(journal_entry_line: line, amount: 500, cleared: true)

      get '/api/v1/accounting/register', params: { account_id: checking.id, start_date: '2026-10-01', end_date: '2026-10-31' }, headers: headers
      expect(json['rows'].find { |r| r['memo'] == 'Deposit' }['status']).to eq('reconciled')
    end

    it "refuses another company's account" do
      other = Company.create!(name: "Other-#{SecureRandom.hex(4)}")
      foreign = other.chart_of_accounts.create!(account_number: '1097', name: 'Theirs', account_type: 'asset', normal_balance: 'debit')
      get '/api/v1/accounting/register', params: { account_id: foreign.id }, headers: headers
      expect(response).to have_http_status(:not_found)
    end
  end

  describe 'bank balances on the bank list and the chart of accounts' do
    it 'gives each bank its bank balance, book balance, difference and lines to review' do
      entry(Date.current - 2, [[checking, 1000, 0], [sales, 0, 1000]])
      bank = company.bank_accounts.create!(bank_name: 'Chase', account_type: 'checking', account_purpose: 'sync_only',
                                           chart_of_account: checking, feed_balance: 1040.5, feed_balance_as_of: 1.hour.ago)
      company.bank_transactions.create!(bank_account: bank, transaction_date: Date.current, amount: 40.5, status: 'unmatched', description: 'X')

      get '/api/v1/bank_accounts', headers: headers
      row = json['bank_accounts'].find { |b| b['id'] == bank.id }
      expect(row).to include('bank_balance' => 1040.5, 'book_balance' => 1000.0, 'balance_difference' => 40.5, 'to_review' => 1)

      get '/api/v1/chart_of_accounts', params: { per_page: 1000 }, headers: headers
      expect(json['items'].find { |a| a['id'] == checking.id }['bank_balance'].to_f).to eq(1040.5)

      get '/api/v1/chart_of_accounts', params: { format: 'tree' }, headers: headers
      flat = ->(nodes) { nodes.flat_map { |n| [n, *flat.call(n['children'] || [])] } }
      expect(flat.call(json['tree']).find { |a| a['id'] == checking.id }['bank_balance'].to_f).to eq(1040.5)
    end
  end

  describe 'Get bank balance' do
    it 'asks the bank, then answers pending until the balance is in' do
      bank = company.bank_accounts.create!(bank_name: 'Chase', account_type: 'checking', account_purpose: 'sync_only',
                                           stripe_fc_account_id: 'fca_x', stripe_fc_status: 'active')
      service = instance_double(StripeBankFeedService)
      allow(StripeBankFeedService).to receive(:new).and_return(service)
      allow(service).to receive(:request_balance!).with(bank).and_return(status: 'requested')
      allow(service).to receive(:balance_status) { |ba| ba.update_columns(feed_balance: 12.5, feed_balance_as_of: Time.current); { status: 'ready' } }

      post "/api/v1/bank_accounts/#{bank.id}/feed/request_balance", headers: headers
      expect(json).to include('status' => 'requested')

      get "/api/v1/bank_accounts/#{bank.id}/feed/balance", headers: headers
      expect(json).to include('status' => 'ready', 'bank_balance' => 12.5)
    end
  end
end
