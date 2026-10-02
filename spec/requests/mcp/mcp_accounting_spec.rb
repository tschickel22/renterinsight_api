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
      expect(items.find { |i| i['id'] == "bank_txn:#{transfer.id}" }['looks_like']).to start_with('transfer')
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
      expect(names).to include('accounting_summary', 'list_bank_transactions', 'list_bills', 'list_invoices', 'list_chart_of_accounts')
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
      expect(summary).not_to have_key('skipped')

      invoices = call_tool(token, 'list_invoices', overdue_only: true).first
      expect(invoices['items'].first).to include('customer' => 'Ana Diaz', 'days_past_due' => 15)

      bills = call_tool(token, 'list_bills', status: 'any').first
      expect(bills['items'].first).to include('vendor' => 'Clayton')
    end

    it 'names the sections a person cannot see instead of reporting zero' do
      limited = connector_user(company, { 'bank_accounts_accounting' => %w[read] })
      summary, = call_tool(connect!(limited)['access_token'], 'accounting_summary')
      expect(summary.keys).to include('bank_feed')
      expect(summary.keys).not_to include('profit_and_loss', 'bills', 'customer_invoices')
      expect(summary['skipped'].join).to include('profit and loss', 'bills')
    end
  end
end
