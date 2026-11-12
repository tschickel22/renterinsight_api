# frozen_string_literal: true

require 'rails_helper'

# The bank's balance at the end of a past day, for the QuickBooks switch's
# statement balance: today's posted balance from Stripe, less every line
# posted after that day. Stripe signs a card's debt negative.
RSpec.describe StripeBankFeedService, '#balance_on' do
  include ActiveSupport::Testing::TimeHelpers

  let(:company) { Company.create!(name: "Bal-#{SecureRandom.hex(4)}") }
  let(:zone) { ActiveSupport::TimeZone['America/Denver'] }
  let(:cutover) { Date.new(2026, 10, 31) }
  let(:now) { Time.utc(2026, 11, 12, 18) }
  let(:checking) do
    company.bank_accounts.create!(bank_name: 'Chase', account_type: 'checking', account_purpose: 'sync_only',
                                  stripe_fc_account_id: 'fca_chk', stripe_fc_status: 'active')
  end
  let(:card) do
    company.bank_accounts.create!(bank_name: 'Visa', account_type: 'credit_card', account_purpose: 'sync_only',
                                  stripe_fc_account_id: 'fca_card', stripe_fc_status: 'active')
  end

  def obj(hash) = Stripe::StripeObject.construct_from(hash)

  def fc_account(id:, category: 'cash', current: 100_000, as_of: now - 1.hour, txn_at: now - 1.hour,
                 balance_status: 'succeeded', txn_status: 'succeeded', permissions: %w[balances transactions], balance: true)
    obj(id: id, status: 'active', category: category, permissions: permissions,
        balance: balance ? { as_of: as_of.to_i, current: { usd: current }, type: category } : nil,
        balance_refresh: { status: balance_status, last_attempted_at: as_of.to_i },
        transaction_refresh: { status: txn_status, last_attempted_at: txn_at.to_i })
  end

  # Denver local times, as a bank in Denver would date them.
  def line(id, amount, posted_at:, status: 'posted', transacted_at: posted_at)
    obj(id: id, amount: amount, status: status, transacted_at: zone.parse(transacted_at).to_i,
        status_transitions: { posted_at: posted_at && zone.parse(posted_at).to_i })
  end

  let(:lines) { [] }

  around { |ex| travel_to(now) { ex.run } }

  before do
    allow(ENV).to receive(:[]).and_call_original
    allow(ENV).to receive(:[]).with('STRIPE_SECRET_KEY').and_return('sk_test_123')
    allow(Stripe::FinancialConnections::Account).to receive(:refresh_account)
    allow(Stripe::FinancialConnections::Transaction).to receive(:list) { obj(data: lines, has_more: false) }
  end

  def service = described_class.new(company)

  it 'works back from today: the balance less every line posted after the cutover day' do
    allow(Stripe::FinancialConnections::Account).to receive(:retrieve).with('fca_chk').and_return(fc_account(id: 'fca_chk', current: 100_000))
    lines.push(
      line('t1', -25_000, posted_at: '2026-11-03 10:00'),            # check cleared after: undo it
      line('t2', 40_000, posted_at: '2026-11-05 09:00'),             # deposit after: undo it
      line('t3', -5_000, posted_at: '2026-10-31 23:30'),             # late on the cutover day, Denver time: stays
      line('t4', -1_200, transacted_at: '2026-10-30 12:00', posted_at: '2026-11-02 08:00'), # bought before, posted after
      line('t5', -9_999, posted_at: nil, status: 'pending', transacted_at: '2026-11-10 12:00'),
      line('t6', -7_777, posted_at: '2026-11-04 12:00', status: 'void'),
      line('t7', -3_000, posted_at: '2026-11-12 11:30')              # after the balance was read
    )

    result = service.balance_on(checking, cutover, zone: zone)

    # 1000.00 - (-250.00 + 400.00 - 12.00)
    expect(result).to include(status: 'ready', lines_after: 3, old_date: false)
    expect(result[:balance]).to eq(BigDecimal('862.00'))
    expect(result[:current]).to eq(BigDecimal('1000.00'))
    expect(Stripe::FinancialConnections::Account).not_to have_received(:refresh_account)
  end

  it 'gives a card in the same signs: what was owed then is negative' do
    allow(Stripe::FinancialConnections::Account).to receive(:retrieve).with('fca_card')
      .and_return(fc_account(id: 'fca_card', category: 'credit', current: -150_000))
    lines.push(line('c1', -20_000, posted_at: '2026-11-06 12:00'), line('c2', 50_000, posted_at: '2026-11-08 12:00'))

    result = service.balance_on(card, cutover, zone: zone)
    # owed 1500 today, 200 charged and 500 paid since: owed 1800 at the cutover
    expect(result[:balance]).to eq(BigDecimal('-1800'))
  end

  it 'asks the bank again when the balance is stale, and answers pending meanwhile' do
    allow(Stripe::FinancialConnections::Account).to receive(:retrieve)
      .and_return(fc_account(id: 'fca_chk', as_of: now - 2.days, txn_at: now - 2.days))
    expect(service.balance_on(checking, cutover, zone: zone)).to eq(status: 'pending')
    expect(Stripe::FinancialConnections::Account).to have_received(:refresh_account).with('fca_chk', { features: %w[balance transactions] })
  end

  it 'asks again when the lines were fetched well before the balance' do
    allow(Stripe::FinancialConnections::Account).to receive(:retrieve)
      .and_return(fc_account(id: 'fca_chk', as_of: now - 1.hour, txn_at: now - 3.hours))
    expect(service.balance_on(checking, cutover, zone: zone)).to eq(status: 'pending')
  end

  it 'asks for the first balance when there has never been one' do
    allow(Stripe::FinancialConnections::Account).to receive(:retrieve).and_return(fc_account(id: 'fca_chk', balance: false))
    expect(service.balance_on(checking, cutover, zone: zone)).to eq(status: 'pending')
    expect(Stripe::FinancialConnections::Account).to have_received(:refresh_account)
  end

  it 'waits while Stripe is still fetching' do
    allow(Stripe::FinancialConnections::Account).to receive(:retrieve)
      .and_return(fc_account(id: 'fca_chk', balance_status: 'pending'))
    expect(service.balance_on(checking, cutover, zone: zone)).to eq(status: 'pending')
    expect(Stripe::FinancialConnections::Account).not_to have_received(:refresh_account)
  end

  it 'uses the balance it has when Stripe will not fetch again yet' do
    allow(Stripe::FinancialConnections::Account).to receive(:retrieve)
      .and_return(fc_account(id: 'fca_chk', as_of: now - 2.days, txn_at: now - 2.days))
    allow(Stripe::FinancialConnections::Account).to receive(:refresh_account)
      .and_raise(Stripe::InvalidRequestError.new('Too soon', nil))
    expect(service.balance_on(checking, cutover, zone: zone)).to include(status: 'ready', balance: BigDecimal('1000'))
  end

  it 'refuses a feed that is a card at the bank but a checking account here' do
    allow(Stripe::FinancialConnections::Account).to receive(:retrieve).and_return(fc_account(id: 'fca_chk', category: 'credit'))
    result = service.balance_on(checking, cutover, zone: zone)
    expect(result).to include(status: 'unavailable')
    expect(result[:reason]).to match(/credit card at the bank/)
  end

  it 'needs balance access on the connection' do
    allow(Stripe::FinancialConnections::Account).to receive(:retrieve)
      .and_return(fc_account(id: 'fca_chk', permissions: %w[transactions]))
    expect(service.balance_on(checking, cutover, zone: zone)[:reason]).to match(/without balance access/)
  end

  it 'says so for an account with no feed' do
    plain = company.bank_accounts.create!(bank_name: 'Plain', account_type: 'checking', account_purpose: 'sync_only')
    expect(service.balance_on(plain, cutover, zone: zone)).to include(status: 'unavailable')
  end

  it 'flags a cutover older than the history banks keep' do
    allow(Stripe::FinancialConnections::Account).to receive(:retrieve).and_return(fc_account(id: 'fca_chk'))
    expect(service.balance_on(checking, Date.new(2026, 6, 30), zone: zone)).to include(old_date: true)
  end

  it 'turns a Stripe failure into a reason, not an error' do
    allow(Stripe::FinancialConnections::Account).to receive(:retrieve).and_raise(Stripe::APIConnectionError.new('down'))
    expect(service.balance_on(checking, cutover, zone: zone)).to include(status: 'unavailable')
  end

  it 'asks Stripe for new lines on a sync (the call it used before does not exist)' do
    allow(Stripe::FinancialConnections::Account).to receive(:refresh_account)
    service.sync_transactions(checking)
    expect(Stripe::FinancialConnections::Account).to have_received(:refresh_account).with('fca_chk', { features: ['transactions'] })
  end
end
