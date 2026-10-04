# frozen_string_literal: true

require 'rails_helper'

# The one-shot import wizard's QuickBooks Online path, against the recorded
# fixture company: balances as of the cutover, open invoices that do not
# post (the opening entry already holds AR), QuickBooks ids kept.
RSpec.describe Accounting::ImportService, 'QuickBooks Online' do
  let(:company) { Company.create!(name: "C-#{SecureRandom.hex(4)}", industry: 'manufactured_housing') }
  let(:user) do
    User.create!(email: "u-#{SecureRandom.hex(4)}@example.com", first_name: 'A', last_name: 'B',
                 password: 'Pass1234!', company_id: company.id, role: 'admin')
  end
  let(:adapter) do
    Accounting::Adapters::QuickbooksOnlineAdapter.new(company, nil, {}, client: Accounting::QboMigration::FixtureClient.new)
  end

  before { allow_any_instance_of(described_class).to receive(:build_adapter).and_return(adapter) }

  it 'imports open invoices at their cutover balance without posting them, and keeps QuickBooks ids' do
    result = described_class.new(company, user).run_import!(
      source_type: 'quickbooks_online', cutover_date: Date.new(2026, 9, 30),
      entities: %w[contacts open_invoices]
    )

    import = company.accounting_imports.find(result[:import_id])
    invoices = company.invoices.where(accounting_import_id: import.id)
    expect(invoices.count).to eq(10)
    expect(invoices.sum(:amount_due)).to eq(BigDecimal('52290.40'))
    expect(company.journal_entries.where(source_entity_type: 'Invoice')).to be_empty
    expect(company.contacts.find_by(quickbooks_id: '101')).to be_present
    expect(invoices.find_by(invoice_number: '1041').contact.quickbooks_id).to eq('101')
  end

  it 'posts opening balances from the trial balance and plugs to Opening Balance Equity' do
    company.chart_of_accounts.find_by!(account_number: '1010').update!(qbo_account_id: '1')

    described_class.new(company, user).run_import!(
      source_type: 'quickbooks_online', cutover_date: Date.new(2026, 9, 30), entities: %w[opening_balances]
    )

    entry = company.journal_entries.order(:id).last
    expect(entry.total_debits).to eq(entry.total_credits)
    checking = entry.journal_entry_lines.find_by(chart_of_account: company.chart_of_accounts.find_by!(account_number: '1010'))
    expect(checking.debit_amount).to eq(BigDecimal('182450.25')) # the trial balance, not CurrentBalance
  end
end
