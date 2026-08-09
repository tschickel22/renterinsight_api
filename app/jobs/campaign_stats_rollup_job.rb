class CampaignStatsRollupJob < ApplicationJob
  queue_as :default

  def perform
    Campaign.where(status: %w[running paused completed]).find_each do |c|
      sends = c.campaign_sends.real
      enrollments = c.campaign_enrollments.real
      stats = {
        'total_sent'   => sends.where.not(sent_at: nil).count,
        'delivered'    => sends.delivered.count,
        'opened'       => sends.where.not(opened_at: nil).count,
        'clicked'      => sends.where.not(clicked_at: nil).count,
        'replied'      => sends.where.not(replied_at: nil).count,
        'bounced'      => sends.where.not(bounced_at: nil).count,
        'unsubscribed' => enrollments.where(status: 'unsubscribed').count,
        # Count by goal_met_at, not status: 'track' goals record a conversion while the
        # enrollment stays active, so status alone would undercount them.
        'goals_met'    => enrollments.where.not(goal_met_at: nil).count,
        'failed'       => enrollments.where(status: 'failed').count,
        'updated_at'   => Time.current.iso8601
      }
      c.update_column(:stats_cache, stats)
    end
  end
end
