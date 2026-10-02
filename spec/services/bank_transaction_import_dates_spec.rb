# frozen_string_literal: true

require 'rails_helper'

# Heartland's first bank CSV had two-digit years. %Y read "5/5/25" as the
# year 25, and every line, then every entry posted from them, landed there.
RSpec.describe BankTransactionImportService, 'dates' do
  let(:company) { Company.create!(name: "C-#{SecureRandom.hex(4)}") }
  let(:gl) do
    company.chart_of_accounts.create!(account_number: '1971', name: 'Checking', account_type: 'asset',
                                      normal_balance: 'debit', is_active: true, is_header: false)
  end
  let(:bank) { company.bank_accounts.create!(bank_name: 'Garrett', account_type: 'checking', account_purpose: 'sync_only', chart_of_account: gl) }
  let(:map) { { date: 0, description: 1, amount: 2 } }

  def import(rows, column_map = map)
    described_class.new(company).import(bank_account: bank, rows: rows, column_map: column_map)
  end

  it 'reads two-digit years as this century' do
    import([['5/5/25', 'SKYLINE HOMES', '-1000.00'], ['12/24/25', 'DEPOSIT', '250.00']])
    expect(bank.bank_transactions.order(:transaction_date).pluck(:transaction_date))
      .to eq([Date.new(2025, 5, 5), Date.new(2025, 12, 24)])
  end

  it 'still reads four-digit and ISO dates as given' do
    import([['05/05/2025', 'A', '-1'], ['2026-01-31', 'B', '-2']])
    expect(bank.bank_transactions.pluck(:transaction_date)).to contain_exactly(Date.new(2025, 5, 5), Date.new(2026, 1, 31))
  end

  it 'honors an explicit format, two-digit years included' do
    import([['05-06-25', 'A', '-1']], map.merge(date_format: '%m-%d-%Y'))
    expect(bank.bank_transactions.first.transaction_date).to eq(Date.new(2025, 5, 6))
  end
end
