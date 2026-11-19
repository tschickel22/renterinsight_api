# frozen_string_literal: true

require 'rails_helper'

# The bank's own balance for the bank cards and the chart of accounts: read
# from Stripe on every sync, asked of the bank at most once a day.
RSpec.describe StripeBankFeedService, 'feed balance' do
  include ActiveSupport::Testing::TimeHelpers

  let(:company) { Company.create!(name: "FB-#{SecureRandom.hex(4)}") }
  let(:service) { described_class.new(company) }

  def bank(type)
    company.bank_accounts.create!(bank_name: type, account_type: type, account_purpose: 'sync_only',
                                  stripe_fc_account_id: "fca_#{type}", stripe_fc_status: 'active')
  end

  def fc(current, as_of)
    Stripe::StripeObject.construct_from(id: 'fca', balance: current.nil? ? nil : { as_of: as_of.to_i, current: { usd: current } })
  end

  before do
    allow(ENV).to receive(:[]).and_call_original
    allow(ENV).to receive(:[]).with('STRIPE_SECRET_KEY').and_return('sk_test_123')
  end

  it 'keeps a bank balance as held and a card balance as owed' do
    checking = bank('checking')
    visa = bank('credit_card')
    as_of = Time.utc(2026, 11, 19, 15)
    allow(Stripe::FinancialConnections::Account).to receive(:retrieve).with('fca_checking').and_return(fc(1_234_56, as_of))
    allow(Stripe::FinancialConnections::Account).to receive(:retrieve).with('fca_credit_card').and_return(fc(-50_00, as_of))

    service.read_feed_balance!(checking)
    service.read_feed_balance!(visa)

    expect(checking.reload).to have_attributes(feed_balance: BigDecimal('1234.56'), feed_balance_as_of: as_of, bank_balance: BigDecimal('1234.56'))
    expect(visa.reload.feed_balance).to eq(BigDecimal('50'))
  end

  it 'leaves the figure alone when Stripe has none or an older one, and never raises' do
    checking = bank('checking')
    checking.update_columns(feed_balance: 10, feed_balance_as_of: Time.utc(2026, 11, 19, 15))
    allow(Stripe::FinancialConnections::Account).to receive(:retrieve).and_return(fc(nil, nil))
    service.read_feed_balance!(checking)
    allow(Stripe::FinancialConnections::Account).to receive(:retrieve).and_return(fc(99_00, Time.utc(2026, 11, 18)))
    service.read_feed_balance!(checking)
    allow(Stripe::FinancialConnections::Account).to receive(:retrieve).and_raise(Stripe::APIConnectionError, 'down')
    expect { service.read_feed_balance!(checking) }.not_to raise_error

    expect(checking.reload.feed_balance).to eq(10)
  end

  it 'asks the bank for a balance at most once a day' do
    checking = bank('checking')
    allow(Stripe::FinancialConnections::Account).to receive(:refresh_account)

    service.request_daily_balance!(checking)
    travel(5.hours) { service.request_daily_balance!(checking.reload) }
    travel(21.hours) { service.request_daily_balance!(checking.reload) }

    expect(Stripe::FinancialConnections::Account).to have_received(:refresh_account).with('fca_checking', { features: ['balance'] }).twice
  end
end
