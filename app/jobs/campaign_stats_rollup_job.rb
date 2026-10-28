class CampaignStatsRollupJob < ApplicationJob
  queue_as :default

  def perform
    Campaign.where(status: %w[running paused completed]).find_each do |c|
      c.update_column(:stats_cache, c.compute_stats)
    end
  end
end
