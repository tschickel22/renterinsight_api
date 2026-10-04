# frozen_string_literal: true

require 'rails_helper'
require Rails.root.join('spec/support/qbo_migration_helpers')

# The whole switch against the recorded fixture company: suggestions, bank
# matching, uncleared items, preview, post and rollback.
RSpec.describe Accounting::QboMigration::Poster do
  include QboMigrationHelpers

  let(:company) { Company.create!(name: "Prairie-#{SecureRandom.hex(4)}", industry: 'manufactured_housing') }
  let(:user) do
    User.create!(email: "u-#{SecureRandom.hex(4)}@example.com", first_name: 'Bo', last_name: 'Keeper',
                 password: 'Pass1234!', company_id: company.id, role: 'admin')
  end
  let!(:books) { build_dealer_books(company) }

  around { |ex| with_qbo_fixture { ex.run } }
  before { stub_claude(company) }

  def start
    import = Accounting::QboMigration::Wizard.start!(company: company, user: user, cutover_date: QboMigrationHelpers::CUTOVER)
    Accounting::QboMigration::Wizard.new(import)
  end

  def ready_wizard
    drive_to_ready(start, books)
  end

  def gl_net(account)
    JournalEntryLine.joins(:journal_entry).merge(JournalEntry.in_ledger)
                    .where(chart_of_account_id: account.id).sum('debit_amount - credit_amount')
  end

  it 'is ready to post once every step is done' do
    wizard = ready_wizard
    preview = wizard.preview_json
    expect(preview[:blockers]).to eq([])
    expect(preview[:can_post]).to be(true)
    expect(preview[:totals][:debit]).to eq(preview[:totals][:credit])
    expect(preview[:open_invoices]).to include(count: 10, total: 52_290.40, ar_balance: 52_290.40, difference: 0.0)
    expect(preview[:open_bills]).to include(count: 7, total: 13_502.11, ap_balance: 13_502.11, difference: 0.0,
                                            bills_total: 14_002.11, vendor_credits_total: 500.0)
    expect(preview[:equity_plug]).to eq(0.0)
    expect(wizard.steps.values.map { |s| s[:done] }).to all(be(true))
  end

  it 'posts one balanced opening entry that ties every account to the QuickBooks trial balance' do
    wizard = ready_wizard
    described_class.new(wizard, user).post!

    import = wizard.import.reload
    expect(import.status).to eq('posted')
    entry = company.journal_entries.find(import.import_config.dig('posted', 'journal_entry_id'))
    expect(entry.entry_date).to eq(QboMigrationHelpers::CUTOVER)
    expect(entry.total_debits).to eq(entry.total_credits)

    tb = JSON.parse(File.read(Rails.root.join('spec/fixtures/quickbooks/migration/report_TrialBalance.json')))
    expect(entry.total_debits).to be > 0
    rows = Accounting::Adapters::QuickbooksOnlineAdapter.parse_trial_balance(tb)[:rows]
    mapped = import.import_config['accounts'].index_by { |r| r['qbo_account_id'] }
    per_dt = Hash.new(BigDecimal('0'))
    rows.each do |r|
      choice = mapped[r[:external_id]]['choice']
      id = choice['action'] == 'map' ? choice['chart_of_account_id'] : company.chart_of_accounts.find_by!(account_number: choice['new_account']['number']).id
      per_dt[id] += r[:balance]
    end
    per_dt.each do |id, expected|
      expect(gl_net(ChartOfAccount.find(id))).to eq(expected), "account #{ChartOfAccount.find(id).account_number}"
    end
    expect(import.results.dig('opening_entry', 'equity_plug')).to eq('0.0')
  end

  it 'carries open invoices and bills that tie to AR and AP and never post them' do
    wizard = ready_wizard
    described_class.new(wizard, user).post!

    invoices = company.invoices.where(accounting_import_id: wizard.import.id)
    expect(invoices.count).to eq(10)
    expect(invoices.sum(:amount_due)).to eq(BigDecimal('52290.40'))
    expect(gl_net(books[:chart]['1110'])).to eq(BigDecimal('52290.40'))
    expect(invoices.find_by(quickbooks_id: '309').amount_due).to eq(BigDecimal('8750.00'))

    bills = company.bills.where(accounting_import_id: wizard.import.id)
    expect(bills.count).to eq(7)
    expect(bills.sum(:balance_due)).to eq(BigDecimal('13502.11'))
    expect(gl_net(books[:chart]['2010'])).to eq(BigDecimal('-13502.11'))
    expect(bills.find_by(quickbooks_id: '501').balance_due).to eq(BigDecimal('2950.00'))

    expect(company.journal_entries.where(source_entity_type: %w[Invoice Bill])).to be_empty
    expect(invoices.where.not(gl_post_error: nil)).to be_empty

    # Later saves (a status flip, a resave) must not post either.
    invoice = invoices.first
    invoice.update!(status: 'viewed')
    expect(company.journal_entries.where(source_entity: invoice)).to be_empty
  end

  it 'keeps QuickBooks ids on the customers and vendors it links' do
    existing = company.contacts.create!(first_name: 'Robert', last_name: 'Kline', email: 'RKline@example.com')
    wizard = ready_wizard
    described_class.new(wizard, user).post!

    expect(existing.reload.quickbooks_id).to eq('103')
    expect(company.contacts.where.not(quickbooks_id: nil).count).to eq(10)
    expect(company.contacts.find_by(quickbooks_id: '109').company_name).to eq('Hillside MHC')
    expect(company.vendors.where.not(quickbooks_id: nil).pluck(:quickbooks_id)).to match_array(%w[201 202 203 204 205])
    invoice = company.invoices.find_by(quickbooks_id: '303')
    expect(invoice.contact).to eq(existing)
    expect(company.bills.find_by(quickbooks_id: '502').vendor.quickbooks_id).to eq('202')
  end

  it 'leaves the uncleared items waiting in the first reconciliation' do
    wizard = ready_wizard
    described_class.new(wizard, user).post!

    chase = books[:banks][:chase]
    opening = chase.bank_reconciliations.find_by(accounting_import_id: wizard.import.id)
    expect(opening.status).to eq('completed')
    expect(opening.statement_ending_balance).to eq(BigDecimal('181300.25'))

    rec = BankReconciliationService.new(company).start(bank_account: chase, statement_date: Date.new(2026, 10, 31),
                                                       statement_ending_balance: BigDecimal('182450.25'))
    expect(rec.beginning_balance).to eq(BigDecimal('181300.25'))
    expect(rec.bank_reconciliation_items.pluck(:amount)).to match_array([BigDecimal('-1200'), BigDecimal('-850'), BigDecimal('3200')])
    rec.bank_reconciliation_items.each { |i| i.update!(cleared: true) }
    rec.recalculate!
    expect(rec.difference).to eq(0)

    amex = books[:banks][:amex].reload
    expect(amex.chart_of_account).to be_present
    expect(amex.chart_of_account.account_number).to eq('2050')
    expect(amex.feed_start_date).to eq(Date.new(2026, 10, 1))
  end

  it 'refuses with the blockers when a step is not done' do
    wizard = start
    expect { described_class.new(wizard, user).post! }
      .to raise_error(described_class::BlockedError) { |e| expect(e.blockers).to include(match(/not mapped/)) }
    expect(company.journal_entries.count).to eq(0)
  end

  it 'creates Opening Balance Equity for the plug when the trial balance is out' do
    wizard = ready_wizard
    cfg = wizard.import.import_config
    row = cfg['accounts'].find { |r| r['qbo_account_id'] == '9' }
    row['tb_balance'] = (BigDecimal(row['tb_balance']) + 10).to_s('F')
    wizard.import.update!(import_config: cfg)
    wizard = Accounting::QboMigration::Wizard.new(wizard.import.reload)
    expect(wizard.preview_json[:equity_plug]).to eq(10.0)

    described_class.new(wizard, user).post!
    obe = company.chart_of_accounts.find_by!(name: 'Opening Balance Equity')
    expect(gl_net(obe)).to eq(BigDecimal('-10'))
  end

  describe 'rollback' do
    it 'voids the entry and removes the open items and reconciliations' do
      wizard = ready_wizard
      described_class.new(wizard, user).post!
      wizard = Accounting::QboMigration::Wizard.new(wizard.import.reload)
      expect(wizard.migration_json[:rollback_available]).to be(true)

      Accounting::QboMigration::Rollback.new(wizard).run!(user)

      import = wizard.import.reload
      expect(import.status).to eq('rolled_back')
      expect(company.journal_entries.find(import.import_config.dig('posted', 'journal_entry_id')).is_void).to be(true)
      expect(company.invoices.where(accounting_import_id: import.id)).to be_empty
      expect(company.bills.where(accounting_import_id: import.id)).to be_empty
      expect(company.bank_reconciliations.where(accounting_import_id: import.id)).to be_empty
      expect(gl_net(books[:chart]['1110'])).to eq(0)
      expect(books[:banks][:amex].reload.chart_of_account_id).to be_nil
    end

    it 'refuses once an imported invoice has a payment applied' do
      wizard = ready_wizard
      described_class.new(wizard, user).post!
      company.invoices.find_by(quickbooks_id: '301').update_column(:amount_paid, 100)

      rollback = Accounting::QboMigration::Rollback.new(Accounting::QboMigration::Wizard.new(wizard.import.reload))
      expect(rollback.refusal).to match(/Invoice 1041 has a payment/)
      expect { rollback.run!(user) }.to raise_error(Accounting::QboMigration::Error)
      expect(wizard.import.reload.status).to eq('posted')
    end

    it 'refuses once a period after cutover is closed' do
      wizard = ready_wizard
      described_class.new(wizard, user).post!
      company.fiscal_periods.create!(fiscal_year: 2026, period_number: 10, start_date: Date.new(2026, 10, 1),
                                     end_date: Date.new(2026, 10, 31), status: 'closed')

      rollback = Accounting::QboMigration::Rollback.new(Accounting::QboMigration::Wizard.new(wizard.import.reload))
      expect(rollback.refusal).to match(/closed for FY2026 period 10/)
    end
  end
end
