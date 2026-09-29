# frozen_string_literal: true

require 'rails_helper'

# Guards that keep the ledger in step with the documents, so a customer's
# books tie out without anyone dissecting them after the fact.
RSpec.describe 'Ledger integrity guards' do
  let(:company)  { Company.create!(name: "C-#{SecureRandom.hex(4)}") }
  let(:location) { company.locations.create!(name: "Loc-#{SecureRandom.hex(4)}", timezone: 'UTC') }
  let(:contact)  { company.contacts.create!(first_name: 'Buyer', last_name: 'One', email: "b-#{SecureRandom.hex(4)}@example.com") }
  let(:settings) { AccountingSettings.for_company(company) }
  let(:accounts) { company.chart_of_accounts.active.postable }
  let(:cash)     { accounts.where(account_type: 'asset', normal_balance: 'debit').order(:account_number).first }
  let(:revenue)  { accounts.where(account_type: 'revenue', normal_balance: 'credit').order(:account_number).first }
  let(:expense)  { accounts.where(account_type: 'expense').order(:account_number).first }

  def post(debit, credit, amount, on: Date.current)
    Accounting::ManualPostingService.new(company).post_simple!(
      debit_account: debit, credit_account: credit, amount: BigDecimal(amount.to_s), memo: 'test', entry_date: on
    )
  end

  def balance(account, as_of: Date.current)
    AccountBalanceService.new(company).balance_as_of(account, as_of)
  end

  def balanced?(je)
    je.journal_entry_lines.sum(&:debit_amount) == je.journal_entry_lines.sum(&:credit_amount)
  end

  describe 'invoice tax posting' do
    before do
      skip 'seed has no AR account' unless settings&.default_ar_account
      settings.update!(auto_post_invoices: true)
      company.tax_codes.create!(name: 'State', rate: 6, is_compound: false, position: 1)
    end

    # Each $1.25 line is taxed 0.075 → 0.08 on the invoice (rounded per line),
    # but the raw snapshots sum to 0.15. The ledger's tax must match the 0.16
    # on the invoice or the entry can't balance and the invoice never posts.
    it 'posts an invoice whose per-line tax rounding differs from the raw total' do
      inv = company.invoices.create!(location: location, contact: contact, invoice_date: Date.current, status: 'draft')
      2.times { inv.invoice_items.create!(description: 'Line', quantity: 1, rate: 1.25, taxable: true) }
      inv.save!
      inv.reload
      expect(inv.tax_amount).to eq(BigDecimal('0.16'))

      inv.update!(status: 'sent')
      # Auto-posting runs after commit, which transactional specs never reach.
      je = Accounting::InvoicePostingService.new(inv.reload).post!
      expect(je).to be_present
      expect(balanced?(je)).to be(true)
      expect(je.journal_entry_lines.sum(&:debit_amount)).to eq(inv.reload.total)
      expect(inv.gl_post_error).to be_nil
    end

    it 'records why an invoice did not post instead of only logging it' do
      settings.update!(default_ar_account_id: nil)

      inv = company.invoices.create!(location: location, contact: contact, invoice_date: Date.current, status: 'draft')
      inv.invoice_items.create!(description: 'Line', quantity: 1, rate: 100)
      inv.update!(status: 'sent')
      expect(Accounting::InvoicePostingService.new(inv.reload).post!).to be_nil
      expect(inv.reload.gl_post_error).to match(/Accounts Receivable/)
    end
  end

  describe "a deal's sale invoice" do
    before do
      skip 'seed has no AR account' unless settings&.default_ar_account
      settings.update!(auto_post_invoices: true)
    end

    def sent_invoice(**attrs)
      inv = company.invoices.create!({ location: location, contact: contact, invoice_date: Date.current, status: 'draft' }.merge(attrs))
      inv.invoice_items.create!(description: 'Home', quantity: 1, rate: 1000)
      inv.save!
      inv.update!(status: 'sent')
      inv.reload
    end

    # GL approval books the sale through the deal's closing entry; posting the
    # invoice it then creates put the sale in AR and revenue twice.
    it 'does not post on its own' do
      deal = Deal.new(company: company, name: 'Sale')
      deal.save!(validate: false)
      inv = sent_invoice(deal_id: deal.id, source_type: 'Deal', source_id: deal.id)

      expect(Accounting::InvoicePostingService.new(inv).post!).to be_nil
      expect(company.journal_entries.where(source_entity: inv)).to be_empty
      expect(inv.gl_post_error).to be_nil
    end

    it 'still posts another invoice that is only linked to the deal' do
      deal = Deal.new(company: company, name: 'Sale')
      deal.save!(validate: false)
      inv = sent_invoice(deal_id: deal.id)

      expect(Accounting::InvoicePostingService.new(inv).post!).to be_present
    end
  end

  describe 'bills with tax' do
    it 'spreads the tax across the expense lines so the entry balances and posts' do
      skip 'seed has no AP account' unless settings&.try(:default_ap_account)

      bill = company.bills.create!(
        bill_date: Date.current, status: 'pending', tax_amount: BigDecimal('10.00'), location_id: location.id,
        bill_line_items_attributes: [
          { chart_of_account_id: expense.id, amount: 60, description: 'A' },
          { chart_of_account_id: expense.id, amount: 40, description: 'B' }
        ]
      )
      je = JournalEntry.find_by(id: bill.reload.journal_entry_id)
      expect(bill.gl_post_error).to be_nil
      expect(je).to be_present
      expect(balanced?(je)).to be(true)
      expect(je.journal_entry_lines.sum(&:debit_amount)).to eq(BigDecimal('110.00'))
    end
  end

  describe 'voided entries' do
    it 'net to zero instead of counting as the negative of the entry' do
      je = post(cash, revenue, 500)
      je.void!(nil)
      expect(balance(cash)).to eq(0)
      expect(balance(revenue)).to eq(0)
    end
  end

  describe 'closed periods' do
    it 'refuses a new entry dated in a closed period' do
      last_month = Date.current.prev_month
      FiscalPeriod.create!(company: company, fiscal_year: last_month.year, period_number: 99,
                           start_date: last_month.beginning_of_month, end_date: last_month.end_of_month, status: 'closed')
      je = company.journal_entries.build(
        entry_date: last_month.beginning_of_month + 3, memo: 'late',
        journal_entry_lines_attributes: [
          { chart_of_account_id: cash.id, debit_amount: 5, credit_amount: 0 },
          { chart_of_account_id: revenue.id, debit_amount: 0, credit_amount: 5 }
        ]
      )
      expect(je).not_to be_valid
      expect(je.errors[:entry_date].join).to match(/closed period/)
    end
  end

  describe 'accounts' do
    it 'will not be deactivated while they hold a balance' do
      post(cash, revenue, 100)
      expect(cash.update(is_active: false)).to be(false)
      expect(cash.errors.full_messages.join).to match(/has a balance of 100.00/)
    end

    it 'can be deactivated once empty' do
      spare = company.chart_of_accounts.create!(account_number: '1999', name: 'Spare', account_type: 'asset', normal_balance: 'debit')
      expect(spare.update(is_active: false)).to be(true)
    end

    it 'refuses journal lines on a header account' do
      header = company.chart_of_accounts.create!(account_number: '1998', name: 'Header', account_type: 'asset',
                                                 normal_balance: 'debit', is_header: true)
      je = company.journal_entries.build(
        entry_date: Date.current, memo: 'x',
        journal_entry_lines_attributes: [
          { chart_of_account_id: header.id, debit_amount: 5, credit_amount: 0 },
          { chart_of_account_id: revenue.id, debit_amount: 0, credit_amount: 5 }
        ]
      )
      expect(je).not_to be_valid
    end
  end

  describe 'opening balances' do
    it 'post a balanced entry against Opening Balance Equity' do
      land = company.chart_of_accounts.create!(account_number: '1590', name: 'Land test', account_type: 'asset', normal_balance: 'debit')
      land.update!(opening_balance: 50_000, opening_balance_date: Date.current.beginning_of_year)

      je = company.journal_entries.find_by(source_entity: land)
      expect(balanced?(je)).to be(true)
      obe = company.chart_of_accounts.find_by(name: 'Opening Balance Equity')
      expect(balance(land)).to eq(50_000)
      expect(balance(obe)).to eq(50_000)
      bs = Reports::BalanceSheetReportService.new(company).generate(as_of_date: Date.current)
      expect(bs[:is_balanced]).to be(true)
    end

    it 'keeps a legacy (unposted) opening balance in the reports with a calculated offset' do
      land = company.chart_of_accounts.create!(account_number: '1591', name: 'Legacy land', account_type: 'asset', normal_balance: 'debit')
      land.update_columns(opening_balance: 25_000, opening_balance_date: Date.current.beginning_of_year)

      expect(balance(land)).to eq(25_000)
      bs = Reports::BalanceSheetReportService.new(company).generate(as_of_date: Date.current)
      expect(bs[:equity].find { |r| r[:account_name].start_with?('Opening Balance Equity (not yet posted)') }[:amount]).to eq(25_000)
      expect(bs[:is_balanced]).to be(true)
      tb = Reports::TrialBalanceReportService.new(company).generate(as_of_date: Date.current)
      expect(tb[:is_balanced]).to be(true)
    end
  end

  describe 'bank matching' do
    it 'matches a deposit to the debit on the bank GL line' do
      service = BankTransactionMatchingService.new(company)
      txn = BankTransaction.new(amount: BigDecimal('250'), transaction_date: Date.current)
      expect(service.send(:matching_amount_condition, txn)).to eq(['debit_amount = ?', BigDecimal('250')])
      withdrawal = BankTransaction.new(amount: BigDecimal('-80'), transaction_date: Date.current)
      expect(service.send(:matching_amount_condition, withdrawal)).to eq(['credit_amount = ?', BigDecimal('80')])
    end
  end
end
