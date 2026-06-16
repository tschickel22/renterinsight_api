# frozen_string_literal: true

require 'rails_helper'

# Regression: tenant deletion used to fail with a PG::ForeignKeyViolation because
# the accounting subsystem (chart_of_accounts <-> bank_accounts circular FK,
# accounting_settings -> chart_of_accounts, journal_entry_lines restrict_with_error,
# bills/budgets/etc.) cannot be torn down in association-declaration order.
# Company#purge_accounting_subsystem! deletes those tables in FK-safe order before
# the rest of the dependent: :destroy cascade.
RSpec.describe Company, '#destroy with accounting data' do
  it 'destroys a tenant that has a fully wired accounting subsystem' do
    company = create(:company, industry: 'manufactured_housing') # auto-seeds chart of accounts
    location = company.default_location || company.locations.first
    coa  = company.chart_of_accounts.first
    coa2 = company.chart_of_accounts.offset(1).first

    bank = company.bank_accounts.create!(
      bank_name: 'Operating', account_type: 'checking', account_purpose: 'operating',
      location_id: location.id, routing_number: '123456789', account_number: '9001',
      chart_of_account: coa
    )
    coa.update!(bank_account: bank) # close the circular FK loop

    AccountingSettings.where(company_id: company.id).first_or_initialize.update!(
      default_ar_account_id: coa.id, default_bank_account_id: bank.id,
      retained_earnings_account_id: coa.id
    )

    company.journal_entries.create!(
      entry_date: Date.current, entry_number: 'JE-1',
      journal_entry_lines_attributes: [
        { chart_of_account_id: coa.id,  debit_amount: 10, credit_amount: 0 },
        { chart_of_account_id: coa2.id, debit_amount: 0,  credit_amount: 10 }
      ]
    )

    cid = company.id
    expect(company.destroy).to be_truthy
    expect(Company.exists?(cid)).to be(false)
    expect(ChartOfAccount.where(company_id: cid).count).to eq(0)
    expect(BankAccount.where(company_id: cid).count).to eq(0)
    expect(AccountingSettings.where(company_id: cid).count).to eq(0)
    expect(JournalEntry.where(company_id: cid).count).to eq(0)
  end
end
