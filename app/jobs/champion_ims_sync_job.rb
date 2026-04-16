# frozen_string_literal: true

# Syncs one ChampionImsRetailer. Triggered from the "Sync Now" button in
# the UI, from the weekly cron, or from a Rails console call.
#
# Runs the sync synchronously inside Solid Queue - typical Heartland-sized
# feeds (50 homes) complete in a few seconds.
class ChampionImsSyncJob < ApplicationJob
  queue_as :default

  # @param retailer_id [Integer]
  # @param trigger [String] 'manual' (UI button / console) or 'scheduled' (cron)
  def perform(retailer_id, trigger: 'manual')
    retailer = ChampionImsRetailer.find_by(id: retailer_id)

    unless retailer
      Rails.logger.warn "[ChampionImsSyncJob] Retailer #{retailer_id} not found, skipping"
      return
    end

    unless retailer.active?
      Rails.logger.info "[ChampionImsSyncJob] Retailer #{retailer.display_label} is inactive, skipping"
      return
    end

    Rails.logger.info "[ChampionImsSyncJob] Starting sync for #{retailer.display_label} (trigger=#{trigger})"
    Scrapers::ChampionImsSyncService.new(retailer, trigger: trigger).call
    Rails.logger.info "[ChampionImsSyncJob] Finished sync for #{retailer.display_label}"
  end
end
