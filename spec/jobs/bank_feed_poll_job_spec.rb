# frozen_string_literal: true

require 'rails_helper'

# Feeds are read every hour without asking the bank again, so a feed whose
# Stripe webhook never arrived still fills in.
RSpec.describe BankFeedPollJob do
  include ActiveJob::TestHelper

  let(:company) { Company.create!(name: "Poll-#{SecureRandom.hex(4)}") }

  def bank(**attrs)
    company.bank_accounts.create!({ bank_name: 'B', account_type: 'checking', account_purpose: 'sync_only' }.merge(attrs))
  end

  it 'queues a read-only sync for each connected feed' do
    live = bank(stripe_fc_account_id: 'fca_1', stripe_fc_status: 'active')
    bank(stripe_fc_account_id: 'fca_2', stripe_fc_status: 'disconnected')
    bank
    bank(stripe_fc_account_id: 'fca_3', stripe_fc_status: 'active', is_deleted: true)

    expect { described_class.perform_now }.to have_enqueued_job(SyncBankFeedJob).exactly(:once)
    expect(SyncBankFeedJob).to have_been_enqueued.with(live.id, refresh: false)
  end

  it 'reads lines without asking Stripe to refresh or for a balance (both are billed)' do
    live = bank(stripe_fc_account_id: 'fca_1', stripe_fc_status: 'active')
    service = instance_double(StripeBankFeedService, sync_transactions: { imported: 0, skipped: 0 })
    allow(StripeBankFeedService).to receive(:new).and_return(service)

    SyncBankFeedJob.perform_now(live.id, refresh: false)
    expect(service).to have_received(:sync_transactions).with(live, refresh: false)
  end
end
