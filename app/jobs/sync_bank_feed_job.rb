# frozen_string_literal: true

class SyncBankFeedJob < ApplicationJob
  queue_as :default

  def perform(bank_account_id)
    bank_account = BankAccount.find_by(id: bank_account_id)
    return unless bank_account
    return unless bank_account.stripe_connected?

    service = StripeBankFeedService.new(bank_account.company)
    result = service.sync_transactions(bank_account)

    Rails.logger.info("[BankFeed] Synced bank_account #{bank_account_id}: #{result.inspect}")
  rescue => e
    Rails.logger.error("[BankFeed] Sync job failed for bank_account #{bank_account_id}: #{e.message}")
  end
end
