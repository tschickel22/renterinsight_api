# frozen_string_literal: true

# Weekly cron dispatcher for Champion IMS feed syncs.
#
# Runs every Sunday at 2am UTC (see config/recurring.yml). Enqueues one
# ChampionImsSyncJob per retailer that is due for sync, so individual
# retailer failures don't block the rest.
class ChampionImsWeeklySyncJob < ApplicationJob
  queue_as :default

  def perform
    retailers = ChampionImsRetailer.due_for_sync
    count     = retailers.count

    Rails.logger.info "[ChampionImsWeeklySyncJob] Dispatching #{count} retailer sync(s)"

    retailers.find_each do |retailer|
      ChampionImsSyncJob.perform_now(retailer.id, trigger: 'scheduled')
    rescue StandardError => e
      Rails.logger.error "[ChampionImsWeeklySyncJob] Failed sync for retailer #{retailer.id}: #{e.message}"
    end

    Rails.logger.info "[ChampionImsWeeklySyncJob] Finished #{count} sync(s)"
  end
end
