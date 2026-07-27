class CampaignAudienceEnrollerJob < ApplicationJob
  queue_as :default

  # TagAssignment#refresh_dynamic_campaigns sets a short-lived "refresh already
  # enqueued" flag per campaign so a bulk tag operation doesn't enqueue N
  # identical jobs. Clearing it HERE — at the very start, before enroll_all's
  # audience query — closes the drop window: any tag committed after this point
  # finds the flag gone and re-enqueues, so a lead tagged moments after a run
  # started can never be silently skipped (the bug that orphaned freshly-tagged
  # leads until the next unrelated tag to the same campaign).
  def perform(campaign_id)
    Rails.cache.delete("campaigns:dynamic_refresh:#{campaign_id}")

    campaign = Campaign.find_by(id: campaign_id)
    return unless campaign && campaign.status == 'running'

    Campaigns::AudienceEnroller.new(campaign: campaign).enroll_all
  end
end
