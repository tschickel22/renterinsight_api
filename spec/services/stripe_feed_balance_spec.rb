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

  it 'asks the bank only when pressed, and a second press within 10 minutes reuses the first' do
    checking = bank('checking')
    allow(Stripe::FinancialConnections::Account).to receive(:refresh_account)

    expect(service.request_balance!(checking)).to include(status: 'requested')
    travel(5.minutes) { expect(service.request_balance!(checking.reload)).to include(status: 'requested') }
    travel(11.minutes) { service.request_balance!(checking.reload) }

    expect(Stripe::FinancialConnections::Account).to have_received(:refresh_account).with('fca_checking', { features: ['balance'] }).twice
  end

  it 'says why when the bank refuses' do
    checking = bank('checking')
    allow(Stripe::FinancialConnections::Account).to receive(:refresh_account)
      .and_raise(Stripe::InvalidRequestError.new('Data cannot be refreshed on inactive accounts.', nil))
    expect(service.request_balance!(checking)).to eq(status: 'unavailable', reason: 'The bank connection is no longer active. Reconnect it')
    expect(checking.reload.feed_balance_requested_at).to be_nil
  end

  it 'reports pending while the bank answers, then keeps the balance' do
    checking = bank('checking')
    as_of = Time.utc(2026, 11, 19, 15)
    pending = Stripe::StripeObject.construct_from(id: 'fca', balance: nil, balance_refresh: { status: 'pending' })
    done = Stripe::StripeObject.construct_from(id: 'fca', balance: { as_of: as_of.to_i, current: { usd: 7_00 } },
                                               balance_refresh: { status: 'succeeded' })
    allow(Stripe::FinancialConnections::Account).to receive(:retrieve).and_return(pending, done)

    expect(service.balance_status(checking)).to eq(status: 'pending')
    expect(service.balance_status(checking)).to eq(status: 'ready')
    expect(checking.reload.feed_balance).to eq(7)
  end
end
