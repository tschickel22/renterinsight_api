# frozen_string_literal: true

require 'rails_helper'

# A QuickBooks switch sets a bank account's feed_start_date to the day
# after cutover. Lines dated before it are already inside the opening
# balances, so neither the Stripe feed nor a CSV import may add them again.
RSpec.describe 'Bank feed start date' do
  let(:company) { Company.create!(name: "C-#{SecureRandom.hex(4)}") }
  let(:gl) do
    company.chart_of_accounts.create!(account_number: '1971', name: 'Checking', account_type: 'asset', normal_balance: 'debit')
  end
  let(:bank) do
    company.bank_accounts.create!(bank_name: 'Chase', account_type: 'checking', account_purpose: 'sync_only', chart_of_account: gl,
                                  stripe_fc_account_id: 'fca_123', stripe_fc_status: 'active', feed_start_date: Date.new(2026, 10, 1))
  end

  describe StripeBankFeedService do
    let(:txns) do
      [
        Struct.new(:id, :transacted_at, :status_transitions, :description, :amount)
              .new('txn_old', Time.zone.local(2026, 9, 30, 12).to_i, nil, 'Before cutover', -5000),
        Struct.new(:id, :transacted_at, :status_transitions, :description, :amount)
              .new('txn_new', Time.zone.local(2026, 10, 1, 12).to_i, nil, 'After cutover', 2500)
      ]
    end

    before do
      allow(ENV).to receive(:[]).and_call_original
      allow(ENV).to receive(:[]).with('STRIPE_SECRET_KEY').and_return('sk_test_123')
      # The service calls refresh, which this stripe gem version does not define.
      without_partial_double_verification { allow(Stripe::FinancialConnections::Account).to receive(:refresh) }
      allow(Stripe::FinancialConnections::Transaction).to receive(:list)
        .and_return(Struct.new(:data, :has_more).new(txns, false))
      allow_any_instance_of(BankTransactionMatchingService).to receive(:auto_match_all)
    end

    it 'skips lines dated before the feed start date and asks only from it' do
      result = StripeBankFeedService.new(company).sync_transactions(bank)

      expect(result).to eq(imported: 1, skipped: 1)
      expect(bank.bank_transactions.pluck(:stripe_txn_id)).to eq(['txn_new'])
      expect(Stripe::FinancialConnections::Transaction).to have_received(:list)
        .with(hash_including(transacted_at: { gte: Date.new(2026, 10, 1).beginning_of_day.to_i }))
    end

    it 'imports everything when no start date is set' do
      bank.update_column(:feed_start_date, nil)
      expect(StripeBankFeedService.new(company).sync_transactions(bank)).to eq(imported: 2, skipped: 0)
    end
  end

  describe BankTransactionImportService do
    it 'skips CSV lines dated before the feed start date' do
      result = described_class.new(company).import(
        bank_account: bank, rows: [['09/30/2026', 'Before', '-10.00'], ['10/01/2026', 'After', '20.00']],
        column_map: { date: 0, description: 1, amount: 2 }
      )
      expect(result).to include(imported: 1, skipped: 1)
      expect(bank.bank_transactions.pluck(:description)).to eq(['After'])
    end
  end
end
