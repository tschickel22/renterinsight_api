# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Accounting::YearEndCloseService do
  let(:company) { Company.create!(name: "Co-#{SecureRandom.hex(3)}") }
  let(:user) do
    User.create!(email: "u-#{SecureRandom.hex(3)}@example.com", first_name: 'T', last_name: 'U',
                 password: 'Pass1234!', company_id: company.id, role: 'admin')
  end
  let(:accounts) { company.chart_of_accounts.active.postable }
  let(:cash)     { accounts.where(account_type: 'asset', normal_balance: 'debit').order(:account_number).first }
  let(:revenue)  { accounts.where(account_type: 'revenue', normal_balance: 'credit').order(:account_number).first }
  let(:expense)  { accounts.where(account_type: 'expense').order(:account_number).first }
  let(:re_account) { AccountingSettings.for_company(company)&.retained_earnings_account }
  let(:year) { Date.current.year - 1 }

  def post(debit, credit, amount)
    Accounting::ManualPostingService.new(company).post_simple!(
      debit_account: debit, credit_account: credit, amount: BigDecimal(amount.to_s),
      memo: 'test', entry_date: Date.new(year, 6, 1)
    )
  end

  def year_balance(account)
    AccountBalanceService.new(company)
      .period_balances(start_date: Date.new(year, 1, 1), end_date: Date.new(year, 12, 31))[account.id]
      .then { |b| b ? b[:total_debits] - b[:total_credits] : 0 }
  end

  before { skip 'seed has no retained earnings account' unless re_account }

  it 'closes a profitable year: credits Retained Earnings with the profit and zeroes P&L accounts' do
    returns = company.chart_of_accounts.create!(account_number: '4990', name: 'Sales Returns',
                                                account_type: 'revenue', normal_balance: 'debit')
    post(cash, revenue, 1000)   # sale
    post(expense, cash, 300)    # expense
    post(returns, cash, 50)     # refund booked to a contra-revenue account

    preview = described_class.new(company).preview(year)
    expect(preview[:netIncome]).to eq(650)

    result = described_class.new(company).close_year!(year, user: user)
    expect(result).to include(success: true)
    expect(result[:net_income]).to eq(650)

    je = result[:journal_entry]
    re_line = je.journal_entry_lines.find { |l| l.chart_of_account_id == re_account.id }
    expect([re_line.debit_amount, re_line.credit_amount]).to eq([0, 650])
    [revenue, expense, returns].each { |a| expect(year_balance(a)).to eq(0) }
  end

  it 'closes a year with a loss by debiting Retained Earnings' do
    post(cash, revenue, 100)
    post(expense, cash, 400)

    result = described_class.new(company).close_year!(year, user: user)
    expect(result[:net_income]).to eq(-300)
    re_line = result[:journal_entry].journal_entry_lines.find { |l| l.chart_of_account_id == re_account.id }
    expect([re_line.debit_amount, re_line.credit_amount]).to eq([300, 0])
  end
end
