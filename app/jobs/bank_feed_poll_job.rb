# frozen_string_literal: true

# Reads new lines for every connected bank feed each hour. Stripe's
# refreshed_transactions webhook is the fast path, but nothing else pulled
# lines after the first sync, so a feed whose webhook never arrived (or whose
# first pull hit "a transaction refresh is still pending") stayed empty for
# good. Easy Homesource connected nine banks on 2026-11-11 and none had
# synced by 2026-11-19. This only reads what Stripe already holds; it does
# not ask the bank to fetch again.
class BankFeedPollJob < ApplicationJob
  queue_as :low

  def perform
    BankAccount.where(stripe_fc_status: 'active', is_deleted: [false, nil])
               .where.not(stripe_fc_account_id: [nil, ''])
               .pluck(:id)
               .each { |id| SyncBankFeedJob.perform_later(id, refresh: false) }
  end
end
