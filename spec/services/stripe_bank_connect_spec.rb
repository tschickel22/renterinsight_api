# frozen_string_literal: true

require 'rails_helper'

# Connect a bank: one Stripe sign in brings every picked account over, each
# as its own bank account with its feed on. Before this, a feed attached to
# one hand-made bank account and only the first picked account was kept, so
# a Wells Fargo login with checking, savings and two cards brought over one.
RSpec.describe StripeBankFeedService do
  let(:company) { Company.create!(name: "Feed-#{SecureRandom.hex(4)}") }
  let(:fc) { Struct.new(:id, :category, :subcategory, :institution_name, :display_name, :last4) }
  let(:accounts) do
    [
      fc.new('fca_chk', 'cash', 'checking', 'Wells Fargo', 'Business Checking', '1111'),
      fc.new('fca_sav', 'cash', 'savings', 'Wells Fargo', 'Savings', '2222'),
      fc.new('fca_visa', 'credit', 'credit_card', 'Wells Fargo', 'Visa', '3333'),
      fc.new('fca_inv', 'investment', 'brokerage', 'Wells Fargo', 'Brokerage', '4444')
    ]
  end
  let(:session) do
    Struct.new(:account_holder, :accounts).new(Struct.new(:customer).new('cus_1'), Struct.new(:data).new(accounts))
  end

  before do
    allow(ENV).to receive(:[]).and_call_original
    allow(ENV).to receive(:[]).with('STRIPE_SECRET_KEY').and_return('sk_test_123')
    allow(Stripe::FinancialConnections::Session).to receive(:retrieve).with('fcsess_1').and_return(session)
    allow(Stripe::FinancialConnections::Account).to receive(:subscribe)
    allow(Stripe::Customer).to receive(:retrieve).with('cus_1')
      .and_return(Struct.new(:metadata).new({ 'ri_company_id' => company.id.to_s }))
    allow_any_instance_of(described_class).to receive(:sync_transactions).and_return(imported: 0, skipped: 0)
  end

  it 'makes a bank account for every bank and card account picked, feed on' do
    rows = described_class.new(company).connect_session_accounts!('fcsess_1')

    expect(rows.map { |r| r[:status] }).to eq(%w[created created created skipped])
    banks = company.bank_accounts.where.not(stripe_fc_account_id: nil).order(:id)
    expect(banks.map { |b| [b.bank_name, b.account_type, b.account_mask, b.stripe_fc_status] }).to eq([
      ['Wells Fargo Business Checking', 'checking', '1111', 'active'],
      ['Wells Fargo Savings', 'savings', '2222', 'active'],
      ['Wells Fargo Visa', 'credit_card', '3333', 'active']
    ])
    expect(banks.map(&:account_purpose).uniq).to eq(['sync_only'])
    expect(Stripe::FinancialConnections::Account).to have_received(:subscribe).exactly(3).times
  end

  it 'connects a bank account added by hand with the same last four instead of duplicating it' do
    by_hand = company.bank_accounts.create!(bank_name: 'WF checking', account_type: 'checking', account_purpose: 'sync_only',
                                            account_mask: '1111')
    rows = described_class.new(company).connect_session_accounts!('fcsess_1')

    expect(rows.first).to include(status: 'connected')
    expect(by_hand.reload).to have_attributes(stripe_fc_account_id: 'fca_chk', stripe_fc_status: 'active', bank_name: 'WF checking')
    expect(company.bank_accounts.where(account_type: 'checking').count).to eq(1)
  end

  it 'reconnects an account it already holds' do
    held = company.bank_accounts.create!(bank_name: 'Visa', account_type: 'credit_card', account_purpose: 'sync_only',
                                         stripe_fc_account_id: 'fca_visa', stripe_fc_status: 'disconnected')
    rows = described_class.new(company).connect_session_accounts!('fcsess_1')

    expect(rows.find { |r| r[:bank_account]&.id == held.id }).to include(status: 'reconnected')
    expect(held.reload.stripe_fc_status).to eq('active')
  end

  it "refuses another company's connection" do
    allow(Stripe::Customer).to receive(:retrieve).with('cus_1')
      .and_return(Struct.new(:metadata).new({ 'ri_company_id' => '999999' }))
    expect { described_class.new(company).connect_session_accounts!('fcsess_1') }.to raise_error(ArgumentError, /another company/)
    expect(company.bank_accounts.count).to eq(0)
  end
end
