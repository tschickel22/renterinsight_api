# frozen_string_literal: true

require 'rails_helper'

# The balance sheet carries all-time asset and liability balances but only
# added this fiscal year's profit to equity, so every prior year nobody ran
# Year-End Close for left it out of balance by that year's net income.
RSpec.describe Reports::BalanceSheetReportService, 'prior-year earnings' do
  let(:company) { Company.create!(name: "Co-#{SecureRandom.hex(3)}") }
  let(:user) do
    User.create!(email: "u-#{SecureRandom.hex(3)}@example.com", first_name: 'T', last_name: 'U',
                 password: 'Pass1234!', company_id: company.id, role: 'admin')
  end
  let(:accounts) { company.chart_of_accounts.active.postable }
  let(:cash)    { accounts.where(account_type: 'asset', normal_balance: 'debit').order(:account_number).first }
  let(:revenue) { accounts.where(account_type: 'revenue').order(:account_number).first }
  let(:this_year) { Date.current.year }
  let(:as_of)     { Date.new(this_year, 12, 31) }

  def sell(amount, on:)
    Accounting::ManualPostingService.new(company).post_simple!(
      debit_account: cash, credit_account: revenue, amount: BigDecimal(amount.to_s),
      memo: 'Sale', entry_date: on
    )
  end

  def report = described_class.new(company).generate(as_of_date: as_of)
  def prior_row(bs) = bs[:equity].find { |r| r[:account_name].start_with?('Retained Earnings (prior years') }
  def current_row(bs) = bs[:equity].find { |r| r[:account_name] == 'Current Year Earnings' }

  before do
    raise 'seeded chart of accounts missing' unless cash && revenue
  end

  it 'balances when last year was never closed, showing that income as prior-year retained earnings' do
    sell(1000, on: Date.new(this_year - 1, 6, 1))
    sell(250, on: Date.new(this_year, 3, 1))

    bs = report
    expect(prior_row(bs)[:amount]).to eq(1000)
    expect(current_row(bs)[:amount]).to eq(250)
    expect(bs[:total_assets]).to eq(bs[:total_liabilities] + bs[:total_equity])
    expect(bs[:is_balanced]).to be(true)
  end

  it 'adds nothing for a year that was closed, so closed income is not counted twice' do
    re_account = AccountingSettings.for_company(company)&.retained_earnings_account
    skip 'no retained earnings account configured by the seed' unless re_account

    sell(1000, on: Date.new(this_year - 1, 6, 1))
    result = Accounting::YearEndCloseService.new(company).close_year!(this_year - 1, user: user)
    expect(result).not_to include(:error)

    bs = report
    expect(prior_row(bs)).to be_nil
    expect(bs[:equity].find { |r| r[:account_id] == re_account.id }[:amount]).to eq(1000)
    expect(bs[:is_balanced]).to be(true)
  end

  it 'adds nothing when all activity is in the current fiscal year' do
    sell(400, on: Date.new(this_year, 2, 1))

    bs = report
    expect(prior_row(bs)).to be_nil
    expect(bs[:is_balanced]).to be(true)
  end
end
