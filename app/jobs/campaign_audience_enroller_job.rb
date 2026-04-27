class CampaignAudienceEnrollerJob < ApplicationJob
  queue_as :default

  def perform(campaign_id)
    campaign = Campaign.find_by(id: campaign_id)
    return unless campaign && campaign.status == 'running'
    Campaigns::AudienceEnroller.new(campaign: campaign).enroll_all
  end
end
