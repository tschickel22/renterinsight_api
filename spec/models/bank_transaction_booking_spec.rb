# frozen_string_literal: true

require 'rails_helper'

# A bank feed line and the ledger must never disagree. Factory Direct had 119
# lines marked categorized with no entry behind them (all 2025 money already
# entered by hand, never linked), and 60 more unmatched lines whose money was
# also already in the books, one Categorize click away from being counted
# twice. Heartland had 28 marked matched by rules that never posted.
RSpec.describe BankTransaction, 'booking' do
  let(:company) { Company.create!(name: "C-#{SecureRandom.hex(4)}") }
  let(:user) { company.users.create!(email: "u-#{SecureRandom.hex(4)}@example.com", first_name: 'Bo', last_name: 'Ok', password: 'Pass1234!', role: 'admin', status: 'active') }

  def gl!(number, name, type)
    company.chart_of_accounts.create!(account_number: number, name: name, account_type: type,
                                      normal_balance: %w[asset expense].include?(type) ? 'debit' : 'credit',
                                      is_active: true, is_header: false)
  end

  let!(:cash_gl) { gl!('1981', 'Checking', 'asset') }
  let!(:supplies) { gl!('6981', 'Supplies', 'expense') }
  let!(:fuel) { gl!('6982', 'Fuel', 'expense') }
  let(:bank) { company.bank_accounts.create!(bank_name: 'Chase', account_type: 'checking', account_purpose: 'sync_only', chart_of_account: cash_gl) }
  let(:date) { Date.new(2026, 3, 10) }

  def txn!(amount, on: bank, description: 'HOME DEPOT')
    company.bank_transactions.create!(bank_account: on, description: description, amount: amount, transaction_date: date, status: 'unmatched')
  end

  def hand_entry!(debit, credit, amount, on: date)
    Accounting::ManualPostingService.new(company).post_simple!(debit_account: debit, credit_account: credit,
                                                               amount: BigDecimal(amount.to_s), memo: 'by hand', entry_date: on)
  end

  around { |ex| Current.set(user: user, company_id: company.id) { ex.run } }

  describe '#categorize! with create_je' do
    it 'posts the entry and links it' do
      t = txn!(-42.50)
      t.categorize!(account: supplies, create_je: true)

      je = t.reload.matched_journal_entry
      expect(t.status).to eq('matched')
      expect(je.journal_entry_lines.find_by(chart_of_account: supplies).debit_amount).to eq(42.50)
      expect(je.journal_entry_lines.find_by(chart_of_account: cash_gl).credit_amount).to eq(42.50)
    end

    it 'saves nothing when the bank account has no GL account' do
      t = txn!(-42.50, on: company.bank_accounts.create!(bank_name: 'Loose', account_type: 'checking', account_purpose: 'sync_only'))

      expect { t.categorize!(account: supplies, create_je: true) }.to raise_error(BankTransaction::PostingError, /not linked to a GL account/)
      expect(t.reload).to have_attributes(status: 'unmatched', category_account_id: nil)
    end

    it 'refuses when the money is already in the books, naming the entry' do
      t = txn!(-42.50)
      booked = hand_entry!(supplies, cash_gl, 42.50)

      expect { t.categorize!(account: supplies, create_je: true) }
        .to raise_error(BankTransaction::AlreadyBooked, /entry #{booked.entry_number}/)
      expect(t.reload.status).to eq('unmatched')
      expect(company.journal_entries.count).to eq(1)
    end

    it 'does not take an entry on the other side, or one already matched to another line' do
      hand_entry!(cash_gl, supplies, 42.50) # money in, not out
      t = txn!(-42.50)
      expect { t.categorize!(account: supplies, create_je: true) }.not_to raise_error

      second = txn!(-42.50, description: 'HOME DEPOT AGAIN')
      expect { second.categorize!(account: supplies, create_je: true) }.not_to raise_error
    end

    it 're-categorizing voids the entry the first categorization posted' do
      t = txn!(-42.50)
      t.categorize!(account: supplies, create_je: true)
      first = t.reload.matched_journal_entry

      t.categorize!(account: fuel, create_je: true)
      expect(first.reload.is_void).to be(true)
      expect(t.reload.matched_journal_entry.journal_entry_lines.find_by(chart_of_account: fuel).debit_amount).to eq(42.50)
    end

    it 'will not categorize over a line matched to an entry booked another way' do
      t = txn!(-42.50)
      t.match_to_journal_entry!(hand_entry!(supplies, cash_gl, 42.50))
      expect { t.categorize!(account: fuel, create_je: true) }.to raise_error(BankTransaction::PostingError, /Unmatch it/)
    end
  end

  describe '#unmatch!' do
    it 'voids the entry its categorization posted, so categorizing again cannot double it' do
      t = txn!(-42.50)
      t.categorize!(account: supplies, create_je: true)
      je = t.reload.matched_journal_entry

      t.unmatch!
      expect(je.reload.is_void).to be(true)
      expect { t.categorize!(account: supplies, create_je: true) }.not_to raise_error
    end

    it 'leaves an entry booked another way alone' do
      t = txn!(-42.50)
      je = hand_entry!(supplies, cash_gl, 42.50)
      t.match_to_journal_entry!(je)

      t.unmatch!
      expect(je.reload.is_void).to be(false)
      expect(t.reload.status).to eq('unmatched')
    end
  end

  describe 'auto-match and rules' do
    let(:service) { BankTransactionMatchingService.new(company) }

    def rule!(auto_confirm:)
      company.bank_rules.create!(name: 'Depot', match_type: 'contains', match_field: 'description', match_value: 'HOME DEPOT',
                                 transaction_direction: 'withdrawal', action_type: 'categorize', assign_account_id: supplies.id,
                                 auto_confirm: auto_confirm, priority: 1, is_active: true)
    end

    it 'matches the entry already in the books before any rule can post a second one' do
      rule!(auto_confirm: true)
      je = hand_entry!(supplies, cash_gl, 42.50)
      t = txn!(-42.50)

      service.auto_match(t)
      expect(t.reload.matched_journal_entry).to eq(je)
      expect(company.journal_entries.count).to eq(1)
    end

    it 'a rule without auto-confirm fills in the category but leaves the line for a person' do
      rule!(auto_confirm: false)
      t = txn!(-42.50)

      service.auto_match(t)
      expect(t.reload).to have_attributes(status: 'unmatched', category_account_id: supplies.id, matched_journal_entry_id: nil)
    end

    it 'a rule with auto-confirm posts, and a line that cannot post stays unmatched' do
      rule!(auto_confirm: true)
      t = txn!(-42.50)
      service.auto_match(t)
      expect(t.reload).to have_attributes(status: 'matched', matched_by: 'rule')
      expect(t.matched_journal_entry).to be_present

      loose = txn!(-9.99, on: company.bank_accounts.create!(bank_name: 'Loose', account_type: 'checking', account_purpose: 'sync_only'))
      service.auto_match(loose)
      expect(loose.reload).to have_attributes(status: 'unmatched', matched_journal_entry_id: nil)
    end
  end

  it 'the integrity check reports matched lines with no entry' do
    txn!(-42.50).update_columns(status: 'matched', category_account_id: supplies.id)
    messages = Accounting::IntegrityCheckService.new(company).issues.map(&:message)
    expect(messages).to include('1 bank line marked matched with no journal entry, totaling 42.50')
  end
end
