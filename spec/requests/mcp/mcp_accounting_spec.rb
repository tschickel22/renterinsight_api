# frozen_string_literal: true

require 'rails_helper'
require_relative '../../support/mcp_connector_helpers'

# The books through the connector. The rules under test: the Accounting plan
# module and the same RBAC keys the accounting screens use; a person sees
# their own company and (location tier) their own locations; a categorized
# bank line posts the same journal entry the app's Categorize panel posts;
# and Undo voids that entry rather than deleting it.
RSpec.describe 'MCP accounting tools', :mcp, type: :request do
  before do
    seed_rbac!
    TenantModuleOverride.create!(company_id: company.id, module_key: 'finance.accounting', is_enabled: true)
  end

  let(:company) { connector_company }
  let(:denver) { company.locations.create!(name: 'Denver', timezone: 'America/Denver') }
  let(:boulder) { company.locations.create!(name: 'Boulder', timezone: 'America/Denver') }
  let(:grants) do
    { 'bank_accounts_accounting' => %w[read update], 'chart_of_accounts' => %w[read], 'bills' => %w[read],
      'finance' => %w[read], 'financial_reports' => %w[read], 'crm' => %w[read] }
  end
  let(:user) { connector_user(company, grants) }
  let(:token) { connect!(user)['access_token'] }

  def gl!(number, name, type, sub_type = nil, normal = nil)
    company.chart_of_accounts.create!(account_number: number, name: name, account_type: type, sub_type: sub_type,
                                      normal_balance: normal || (%w[asset expense].include?(type) ? 'debit' : 'credit'),
                                      is_active: true, is_header: false)
  end

  let!(:cash_gl) { gl!('1991', 'Operating Checking', 'asset', 'bank') }
  let!(:supplies) { gl!('6991', 'Shop Supplies', 'expense', 'operating_expense') }
  let!(:card_liability) { gl!('2991', 'Amex Card', 'liability', 'current_liability') }
  let!(:sales) { gl!('4991', 'Home Sales', 'revenue', 'sales_revenue') }

  def bank!(company_for: company, location: denver, gl: cash_gl)
    company_for.bank_accounts.create!(bank_name: 'Chase', account_type: 'checking', account_purpose: 'sync_only',
                                      location: location, chart_of_account: gl)
  end

  let!(:bank) { bank!(gl: cash_gl) }

  def txn!(description, amount, status: 'unmatched', account: nil, on: bank, date: Date.current - 3)
    company.bank_transactions.create!(bank_account: on, description: description, amount: amount,
                                      transaction_date: date, status: status, category_account: account)
  end

  describe 'payee keys' do
    {
      'POS DEBIT 09/14 HOME DEPOT #4521 DENVER CO' => 'home depot denver',
      'ORIG CO NAME:LOWES                  ORIG ID:9493560001 DESC DATE:240915 CO ENTRY DESCR:ACH PMT' => 'lowes',
      'ACH DEBIT 21ST MORTGAGE CORP PPD ID: 123456789' => '21st mortgage corp',
      'DOLLAR GENERAL #1234GARRETT IN' => 'dollar general',
      'CHECK #1043' => 'check',
      '123456789 ONLINE OR MOBILE BANKING TRANSFER TO CHK 1234' => 'transfer'
    }.each do |description, key|
      it "reads #{description.inspect} as #{key.inspect}" do
        expect(McpTools::BankPayee.key(description)).to eq(key)
      end
    end
  end

  describe 'list_bank_transactions' do
    it 'suggests the account this dealer used before for the same payee, with a confidence' do
      3.times { |i| txn!("ORIG CO NAME:LOWES ORIG ID:#{900 + i} DESC DATE:2409#{10 + i}", -50 - i, status: 'matched', account: supplies) }
      new_line = txn!('ORIG CO NAME:LOWES ORIG ID:999 DESC DATE:240930', -77.12)

      result, error = call_tool(token, 'list_bank_transactions')
      expect(error).to be_falsey
      row = result['items'].find { |i| i['id'] == "bank_txn:#{new_line.id}" }
      expect(row['suggested_account']).to include('id' => "gl_account:#{supplies.id}", 'times_used' => 3,
                                                  'confidence' => 'high', 'based_on' => 'same payee')
      expect(result['totals']).to include('unmatched' => 1, 'matched' => 3)
    end

    it 'suggests excluding a payee that was excluded before' do
      2.times { |i| txn!("ONLINE TRANSFER TO SAV #{1000 + i}", -100, status: 'excluded') }
      line = txn!('ONLINE TRANSFER TO SAV 1099', -100)

      row = call_tool(token, 'list_bank_transactions').first['items'].find { |i| i['id'] == "bank_txn:#{line.id}" }
      expect(row['suggested_action']).to include('action' => 'exclude', 'times_used' => 2)
      expect(row).not_to have_key('suggested_account')
    end

    it 'never suggests from history for checks, and flags transfers' do
      txn!('CHECK 1001', -500, status: 'matched', account: supplies)
      check = txn!('CHECK 1002', -800)
      transfer = txn!('ONLINE TRANSFER TO SAV 1234', -1000)

      items = call_tool(token, 'list_bank_transactions').first['items']
      expect(items.find { |i| i['id'] == "bank_txn:#{check.id}" }).not_to have_key('suggested_account')
      expect(items.find { |i| i['id'] == "bank_txn:#{transfer.id}" }['looks_like']).to eq('transfer')
      expect(items.find { |i| i['id'] == "bank_txn:#{check.id}" }['looks_like']).to eq('check')
    end

    # Staging Summit Park: plain payee names ("Typographic", "Rocket Rides")
    # matched no wording, and looks_like was missing from every line.
    it 'gives every line a looks_like, from the direction when the wording says nothing' do
      deposit = txn!('Typographic', 1000)
      payment = txn!('Rocket Rides', -100)

      items = call_tool(token, 'list_bank_transactions').first['items']
      expect(items.find { |i| i['id'] == "bank_txn:#{deposit.id}" }).to include('looks_like' => 'deposit', 'looks_like_note' => a_string_including('match'))
      expect(items.find { |i| i['id'] == "bank_txn:#{payment.id}" }).to include('looks_like' => 'payment')
      expect(items).to all(include('looks_like'))
    end

    # Staging: a deposit was suggested to 1030 Savings / Reserve at medium
    # confidence from one earlier booking.
    it 'says plainly that a bank account suggestion books a transfer, at low confidence from one use' do
      savings = gl!('1993', 'Savings / Reserve', 'asset', 'bank')
      txn!('Typographic', 1000, status: 'matched', account: savings)
      line = txn!('Typographic', 1000)

      row = call_tool(token, 'list_bank_transactions').first['items'].find { |i| i['id'] == "bank_txn:#{line.id}" }
      expect(row['suggested_account']).to include('id' => "gl_account:#{savings.id}", 'times_used' => 1, 'out_of' => 1,
                                                  'confidence' => 'low', 'books_as' => 'transfer between bank accounts')
      expect(row['looks_like']).to eq('transfer')
      expect(row['looks_like_note']).to include('transfer between bank accounts', 'not income or expense')
    end

    it 'keeps confidence low below three uses, however consistent' do
      2.times { |i| txn!("SHERWIN WILLIAMS #{i}", -40, status: 'matched', account: supplies) }
      line = txn!('SHERWIN WILLIAMS', -41)
      row = call_tool(token, 'list_bank_transactions').first['items'].find { |i| i['id'] == "bank_txn:#{line.id}" }
      expect(row['suggested_account']).to include('times_used' => 2, 'confidence' => 'low')
      expect(row['suggested_account']).not_to have_key('books_as')
      expect(row['looks_like']).to eq('payment')
    end

    it 'says whether a matched line posted its own entry or was linked to an existing one' do
      posted = txn!('POS DEBIT HOME DEPOT', -60)
      call_tool(token, 'categorize_bank_transaction', id: "bank_txn:#{posted.id}", account_id: "gl_account:#{supplies.id}")
      existing = Accounting::ManualPostingService.new(company).post_simple!(debit_account: cash_gl, credit_account: sales, amount: 250,
                                                                            memo: 'Down payment', entry_date: Date.current - 2)
      linked = txn!('REMOTE DEPOSIT', 250, date: Date.current - 2)
      linked.match_to_journal_entry!(existing, source: 'manual')
      bare = txn!('OLD CATEGORIZED', -5, status: 'matched', account: supplies)

      items = call_tool(token, 'list_bank_transactions', status: 'matched').first['items'].index_by { |i| i['id'] }
      expect(items["bank_txn:#{posted.id}"]).to include('booked_by' => 'posted')
      expect(items["bank_txn:#{posted.id}"]['journal_entry']['id']).to eq("journal_entry:#{posted.reload.matched_journal_entry_id}")
      expect(items["bank_txn:#{linked.id}"]).to include('booked_by' => 'linked')
      expect(items["bank_txn:#{bare.id}"]).to include('booked_by' => 'not_posted')
    end

    # Staging bank_txn:1: un-excluded in the app, which leaves the reason.
    it 'drops a stale excluded_reason from a line that is no longer excluded' do
      line = txn!('ROCKET RIDES', -10)
      line.update_columns(excluded_reason: 'Excluded by rule')
      row = call_tool(token, 'list_bank_transactions').first['items'].find { |i| i['id'] == "bank_txn:#{line.id}" }
      expect(row).not_to have_key('excluded_reason')
    end

    it 'warns about a bank account linked to a GL account that is not a bank or cash account' do
      receivables = gl!('1994', 'Customer Receivables', 'asset', 'accounts_receivable')
      bank!(gl: receivables)
      accounts = call_tool(token, 'list_bank_transactions').first['bank_accounts']
      mislinked = accounts.find { |a| a.dig('gl_account', 'id') == "gl_account:#{receivables.id}" }
      expect(mislinked['gl_account_warning']).to include('1994 Customer Receivables', 'accounts receivable', 'not a bank or cash account')
      expect(accounts.find { |a| a['id'] == bank.id }).not_to have_key('gl_account_warning')
    end

    it "keeps to the person's locations and company" do
      other = connector_company
      other_gl = other.chart_of_accounts.create!(account_number: '1992', name: 'Theirs', account_type: 'asset', normal_balance: 'debit')
      other_bank = other.bank_accounts.create!(bank_name: 'Other', account_type: 'checking', account_purpose: 'sync_only', chart_of_account: other_gl)
      other.bank_transactions.create!(bank_account: other_bank, description: 'THEIRS', amount: -1, transaction_date: Date.current, status: 'unmatched')
      boulder_bank = bank!(location: boulder)
      txn!('BOULDER ONLY', -5, on: boulder_bank)
      txn!('DENVER LINE', -6)

      denver_user = connector_user(company, grants, location: denver)
      items = call_tool(connect!(denver_user)['access_token'], 'list_bank_transactions').first['items']
      expect(items.map { |i| i['description'] }).to eq(['DENVER LINE'])
    end

    it 'is refused without the bank feed permission, and without the Accounting module' do
      no_bank = connector_user(company, grants.except('bank_accounts_accounting'))
      _, error, text = call_tool(connect!(no_bank)['access_token'], 'list_bank_transactions')
      expect(error).to be(true)
      expect(text).to include('bank accounts accounting')

      TenantModuleOverride.where(company_id: company.id, module_key: 'finance.accounting').update_all(is_enabled: false)
      _, error, text = call_tool(token, 'list_bank_transactions')
      expect(error).to be(true)
      expect(text).to include("not part of this account's plan")
    end
  end

  describe 'categorize_bank_transaction' do
    let(:line) { txn!('POS DEBIT HOME DEPOT #4521', -120.50) }

    it 'posts the same journal entry the Categorize panel does, and Undo voids it' do
      result, error, text = call_tool(token, 'categorize_bank_transaction', id: "bank_txn:#{line.id}",
                                                                           account_id: "gl_account:#{supplies.id}", memo: 'Shop lumber')
      expect(error).to be_falsey, text
      line.reload
      expect(line).to have_attributes(status: 'matched', category_account_id: supplies.id, matched_by: 'manual', memo: 'Shop lumber')
      je = line.matched_journal_entry
      debit = je.journal_entry_lines.find { |l| l.debit_amount.positive? }
      credit = je.journal_entry_lines.find { |l| l.credit_amount.positive? }
      expect([debit.chart_of_account_id, debit.debit_amount]).to eq([supplies.id, 120.50.to_d])
      expect([credit.chart_of_account_id, credit.credit_amount]).to eq([cash_gl.id, 120.50.to_d])
      expect(result.dig('journal_entry', 'debit', 'id')).to eq("gl_account:#{supplies.id}")

      change = McpChange.last
      outcome = McpTools::Undo.undo!(change, by: user)
      expect(outcome).to be_undone
      expect(je.reload).to be_is_void
      expect(je.reversed_by).to be_present
      expect(line.reload).to have_attributes(status: 'unmatched', category_account_id: nil, matched_journal_entry_id: nil)
      expect(McpTools::AccountingArea.label(change.record_type)).to eq('bank transaction')
    end

    it 'refuses a line that is already categorized, and saves nothing when no entry can be posted' do
      done = txn!('ALREADY', -10, status: 'matched', account: supplies)
      _, error, text = call_tool(token, 'categorize_bank_transaction', id: "bank_txn:#{done.id}", account_id: "gl_account:#{supplies.id}")
      expect(error).to be(true)
      expect(text).to include('already matched')

      unlinked = bank!(gl: nil)
      loose = txn!('NO GL', -10, on: unlinked)
      _, error, text = call_tool(token, 'categorize_bank_transaction', id: "bank_txn:#{loose.id}", account_id: "gl_account:#{supplies.id}")
      expect(error).to be(true)
      expect(text).to include('not linked to a GL account')
      expect(loose.reload.status).to eq('unmatched')
    end

    it 'refuses header accounts and needs update on the bank feed' do
      header = company.chart_of_accounts.create!(account_number: '6990', name: 'Expenses', account_type: 'expense',
                                                 normal_balance: 'debit', is_header: true, is_active: true)
      _, error, text = call_tool(token, 'categorize_bank_transaction', id: "bank_txn:#{line.id}", account_id: "gl_account:#{header.id}")
      expect(error).to be(true)
      expect(text).to include('header')

      reader = connector_user(company, grants.merge('bank_accounts_accounting' => %w[read]))
      _, error, text = call_tool(connect!(reader)['access_token'], 'categorize_bank_transaction',
                                 id: "bank_txn:#{line.id}", account_id: "gl_account:#{supplies.id}")
      expect(error).to be(true)
      expect(text).to include('does not allow update')
    end
  end

  describe 'exclude_bank_transaction' do
    it 'excludes with a reason, and Undo puts it back' do
      line = txn!('ONLINE TRANSFER TO SAV', -1000)
      _, error = call_tool(token, 'exclude_bank_transaction', id: "bank_txn:#{line.id}", reason: 'Transfer to savings, booked there')
      expect(error).to be_falsey
      expect(line.reload).to have_attributes(status: 'excluded', excluded_reason: 'Transfer to savings, booked there')

      expect(McpTools::Undo.undo!(McpChange.last, by: user)).to be_undone
      expect(line.reload.status).to eq('unmatched')
    end
  end

  describe 'read-only connection' do
    it 'hides the bank feed writes but keeps the reads' do
      names = mcp_post(connect!(user, allow_write: false)['access_token'], 'tools/list').dig('result', 'tools').map { |t| t['name'] }
      expect(names).to include('accounting_summary', 'list_bank_transactions', 'list_bills', 'list_invoices', 'list_chart_of_accounts',
                               'get_journal_entry')
      expect(names).not_to include('categorize_bank_transaction', 'exclude_bank_transaction')
    end
  end

  describe 'accounting_summary, list_bills, list_invoices' do
    it 'summarizes profit from posted entries, cash, the feed, bills and receivables' do
      Accounting::ManualPostingService.new(company).post_simple!(debit_account: cash_gl, credit_account: sales, amount: 5000,
                                                                 memo: 'Sale', entry_date: Date.current)
      txn!('UNBOOKED', -40)
      company.bills.create!(vendor_name: 'Clayton', bill_date: Date.current - 40, due_date: Date.current - 10,
                            status: 'draft', total_amount: 900, location: denver)
      contact = company.contacts.create!(first_name: 'Ana', last_name: 'Diaz', location_id: denver.id)
      invoice = company.invoices.create!(invoice_number: "INV-#{SecureRandom.hex(3)}", contact: contact, status: 'sent',
                                         invoice_date: Date.current - 45, due_date: Date.current - 15, location: denver)
      invoice.update_columns(total: 300, amount_due: 300) # totals come from line items; none here

      summary, error, text = call_tool(token, 'accounting_summary')
      expect(error).to be_falsey, text
      expect(summary.dig('profit_and_loss', 'period', 'revenue')).to eq(5000.0)
      expect(summary.dig('cash', 'total')).to eq(5000.0)
      expect(summary.dig('bank_feed', 'unmatched')).to eq(1)
      expect(summary.dig('customer_invoices', 'aging', 'days_1_30')).to eq(300.0)
      expect(summary.dig('bills', 'drafts_not_entered')).to eq(1)
      expect(summary['skipped']).to eq([])

      invoices = call_tool(token, 'list_invoices', overdue_only: true).first
      expect(invoices['items'].first).to include('customer' => 'Ana Diaz', 'days_past_due' => 15, 'aging_bucket' => 'days_1_30')

      bills = call_tool(token, 'list_bills', status: 'any').first
      expect(bills['items'].first).to include('vendor' => 'Clayton')
    end

    def invoice!(number, status:, due:, owed:)
      company.invoices.create!(invoice_number: number, status: status, invoice_date: due - 15, due_date: due, location: denver)
             .tap { |i| i.update_columns(status: status, total: owed, amount_due: owed) } # callbacks move status; pin it
    end

    # Staging Summit Park: the summary said 144 invoices and list_invoices
    # 104 with the same balance, because the summary counted drafts and paid
    # ones too. And a 301 day old loan invoice was thought to be in current
    # because a newer one of the same amount was.
    it 'ages and counts the same open invoices in the summary and the list' do
      old = invoice!('LN-3002-P01', status: 'overdue', due: Date.current - 301, owed: 2309.14)
      invoice!('LN-3002-P11', status: 'sent', due: Date.current + 3, owed: 2309.14)
      invoice!('INV-PAID', status: 'sent', due: Date.current - 5, owed: 100).update_columns(status: 'paid', amount_due: 0)
      invoice!('INV-DRAFT', status: 'draft', due: Date.current - 5, owed: 400)

      summary = call_tool(token, 'accounting_summary').first['customer_invoices']
      list = call_tool(token, 'list_invoices').first
      expect(summary).to include('open_invoices' => 2, 'open_balance' => 4618.28, 'counted' => a_string_including('balance due'))
      expect(summary['aging']).to include('current' => 2309.14, 'days_90_plus' => 2309.14, 'days_1_30' => 0.0)
      expect(summary['aging_counts']).to include('current' => 1, 'days_90_plus' => 1)
      expect(summary['aging_invoices']).to eq('current' => ['LN-3002-P11'], 'days_90_plus' => ['LN-3002-P01'])
      expect(summary['oldest_past_due']).to include('invoice_number' => 'LN-3002-P01', 'days_past_due' => 301)
      expect(list['totals'].except('matching_invoices')).to eq(summary)
      expect(list['totals']['matching_invoices']).to eq(2)
      expect(list['items'].find { |i| i['id'] == "invoice:#{old.id}" }).to include('days_past_due' => 301, 'aging_bucket' => 'days_90_plus')

      any = call_tool(token, 'list_invoices', status: 'any').first['totals']
      expect(any).to include('matching_invoices' => 4, 'open_invoices' => 2)
    end

    it 'lists the largest balances first on request and says how many it did not show' do
      invoice!('INV-SMALL', status: 'overdue', due: Date.current - 400, owed: 100)
      invoice!('INV-BIG', status: 'overdue', due: Date.current - 40, owed: 9000)
      invoice!('INV-MID', status: 'overdue', due: Date.current - 90, owed: 500)

      oldest = call_tool(token, 'list_invoices', overdue_only: true, limit: 2).first
      expect(oldest['items'].map { |i| i['invoice_number'] }).to eq(%w[INV-SMALL INV-MID])
      expect(oldest['more_not_shown']).to eq(1)

      largest = call_tool(token, 'list_invoices', overdue_only: true, sort: 'largest', limit: 2).first
      expect(largest['items'].map { |i| i['invoice_number'] }).to eq(%w[INV-BIG INV-MID])
    end

    it 'rolls receivables up by customer, largest balance first' do
      ana = company.contacts.create!(first_name: 'Ana', last_name: 'Diaz', location_id: denver.id)
      joe = company.contacts.create!(first_name: 'Joe', last_name: 'Williams', location_id: denver.id)
      3.times { |n| invoice!("LN-P0#{n}", status: 'overdue', due: Date.current - (30 * (n + 1)), owed: 2309.14).update_columns(contact_id: joe.id) }
      invoice!('INV-ANA', status: 'overdue', due: Date.current - 10, owed: 500).update_columns(contact_id: ana.id)

      rows = call_tool(token, 'accounting_summary').first.dig('customer_invoices', 'by_customer')
      expect(rows.first).to include('customer' => 'Joe Williams', 'open_invoices' => 3, 'balance' => 6927.42,
                                    'oldest_days_past_due' => 90, 'customer_id' => "contact:#{joe.id}")
      expect(rows.second).to include('customer' => 'Ana Diaz', 'open_invoices' => 1)
    end

    it 'says whether the month is open, closed or locked' do
      summary = call_tool(token, 'accounting_summary').first
      expect(summary.dig('profit_and_loss', 'fiscal_period')).to include('status' => 'not_set_up')

      FiscalPeriod.generate_for_year(company, Date.current.year)
      company.fiscal_periods.find_by(fiscal_year: Date.current.year, period_number: Date.current.month)
             .update!(status: 'closed', closed_at: Time.current)
      period = call_tool(token, 'accounting_summary').first.dig('profit_and_loss', 'fiscal_period')
      expect(period).to include('status' => 'closed', 'period_number' => Date.current.month)
    end

    it 'says when the bank feed looks stopped, not just behind' do
      txn!('OLD DEPOSIT', 100, date: Date.current - 60)
      feed = call_tool(token, 'accounting_summary').first['bank_feed']
      expect(feed['newest_line']).to eq((Date.current - 60).iso8601)
      expect(feed['feed_note']).to include('60 days old', 'looks stopped')

      txn!('NEW DEPOSIT', 100, date: Date.current - 2)
      expect(call_tool(token, 'accounting_summary').first['bank_feed']).not_to have_key('feed_note')
    end

    it 'says which sections follow the dates, and splits the bank feed by period' do
      summary = call_tool(token, 'accounting_summary', start_date: (Date.current - 10).iso8601,
                                                        end_date: Date.current.iso8601).first
      expect(summary['dates_apply_to']).to include('profit_and_loss only', 'as of today')
      expect(summary['bank_feed'].keys).to include('unmatched_in_period', 'unmatched_through_period_end')
    end

    it 'says when invoices and payments are not set to post, so a zero P&L is explained' do
      notes = call_tool(token, 'accounting_summary').first.dig('profit_and_loss', 'notes')
      expect(notes.join).to include('auto post invoices is off', 'auto post payments is off')

      AccountingSettings.for_company(company).update!(auto_post_invoices: true, auto_post_payments: true)
      expect(call_tool(token, 'accounting_summary').first['profit_and_loss']).not_to have_key('notes')
    end

    it 'leaves a bank account linked to a non cash GL account out of the cash total, with a warning' do
      receivables = gl!('1994', 'Customer Receivables', 'asset', 'accounts_receivable')
      bank!(gl: receivables)
      Accounting::ManualPostingService.new(company).post_simple!(debit_account: receivables, credit_account: sales, amount: 700,
                                                                 memo: 'Invoice', entry_date: Date.current)
      cash = call_tool(token, 'accounting_summary').first['cash']
      expect(cash['total']).to eq(0.0)
      flagged = cash['accounts'].find { |a| a.dig('gl_account', 'number') == '1994' }
      expect(flagged).to include('book_balance' => 700.0, 'in_total' => false, 'gl_account_warning' => a_string_including('which is an accounts receivable account'))
    end

    it 'names the sections a person cannot see instead of reporting zero' do
      limited = connector_user(company, { 'bank_accounts_accounting' => %w[read] })
      summary, = call_tool(connect!(limited)['access_token'], 'accounting_summary')
      expect(summary.keys).to include('bank_feed')
      expect(summary.keys).not_to include('profit_and_loss', 'bills', 'customer_invoices')
      expect(summary['skipped'].join).to include('profit and loss', 'bills')
    end
  end

  describe 'get_journal_entry' do
    let(:je_grants) { grants.merge('journal_entries' => %w[read]) }
    let(:je_token) { connect!(connector_user(company, je_grants))['access_token'] }

    it 'returns an entry by id or number with its lines, and the reversal links once voided' do
      je = Accounting::ManualPostingService.new(company).post_simple!(debit_account: supplies, credit_account: cash_gl, amount: 42.5,
                                                                      memo: 'Shop rags', entry_date: Date.current - 1, location_id: denver.id)
      je.void!(user)
      reversal = je.reload.reversed_by

      result, error, text = call_tool(je_token, 'get_journal_entry', id: "journal_entry:#{je.id}")
      expect(error).to be_falsey, text
      expect(result).to include('entry_number' => je.entry_number, 'date' => (Date.current - 1).iso8601, 'memo' => 'Shop rags',
                                'is_void' => true, 'total_debits' => 42.5, 'total_credits' => 42.5,
                                'reversed_by' => { 'id' => "journal_entry:#{reversal.id}", 'entry_number' => reversal.entry_number })
      expect(result['lines']).to contain_exactly(
        a_hash_including('account_number' => '6991', 'account_name' => 'Shop Supplies', 'debit' => 42.5, 'location' => 'Denver'),
        a_hash_including('account_number' => '1991', 'account_name' => 'Operating Checking', 'credit' => 42.5)
      )
      expect(result['lines'].first.keys & %w[debit credit]).to be_one

      by_number, = call_tool(je_token, 'get_journal_entry', entry_number: reversal.entry_number)
      expect(by_number).to include('id' => "journal_entry:#{reversal.id}", 'is_void' => false,
                                   'reverses' => { 'id' => "journal_entry:#{je.id}", 'entry_number' => je.entry_number })
    end

    it 'is read only, company scoped, and needs journal entries read' do
      tool = McpTools::GetJournalEntry.to_h
      expect(tool[:title]).to be_present
      expect(tool.dig(:annotations, :readOnlyHint)).to be(true)

      other = connector_company
      theirs_gl = other.chart_of_accounts.create!(account_number: '1', name: 'A', account_type: 'asset', normal_balance: 'debit')
      theirs_rev = other.chart_of_accounts.create!(account_number: '2', name: 'B', account_type: 'revenue', normal_balance: 'credit')
      theirs = Accounting::ManualPostingService.new(other).post_simple!(debit_account: theirs_gl, credit_account: theirs_rev,
                                                                        amount: 1, memo: 'Theirs')
      _, error, text = call_tool(je_token, 'get_journal_entry', id: "journal_entry:#{theirs.id}")
      expect(error).to be(true)
      expect(text).to include('No record')

      _, error, text = call_tool(token, 'get_journal_entry', id: "journal_entry:#{theirs.id}")
      expect(error).to be(true)
      expect(text).to include('journal entries')
    end

    it 'shows a location tier person only entries touching their locations or none' do
      mine = Accounting::ManualPostingService.new(company).post_simple!(debit_account: supplies, credit_account: cash_gl, amount: 5,
                                                                        memo: 'Denver', location_id: denver.id)
      elsewhere = Accounting::ManualPostingService.new(company).post_simple!(debit_account: supplies, credit_account: cash_gl, amount: 6,
                                                                             memo: 'Boulder', location_id: boulder.id)
      denver_token = connect!(connector_user(company, je_grants, location: denver))['access_token']
      expect(call_tool(denver_token, 'get_journal_entry', id: "journal_entry:#{mine.id}")[1]).to be_falsey
      expect(call_tool(denver_token, 'get_journal_entry', id: "journal_entry:#{elsewhere.id}")[1]).to be(true)
    end
  end
end
