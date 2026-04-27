class CampaignSchedulerJob < ApplicationJob
  queue_as :default

  def perform
    promote_scheduled_to_running
    enroll_running_without_enrollments
    dispatch_due_enrollments
    finalize_completed_campaigns
  end

  private

  def promote_scheduled_to_running
    Campaign.where(status: 'scheduled').where('scheduled_at <= ?', Time.current).find_each do |c|
      c.update!(status: 'running')
      if defined?(WebhookService)
        WebhookService.fire(company_id: c.company_id, event: 'campaign.started', payload: { campaign_id: c.id })
      end
      CampaignAudienceEnrollerJob.perform_later(c.id)
    end
  end

  def enroll_running_without_enrollments
    Campaign.running
            .left_joins(:campaign_enrollments)
            .group('campaigns.id')
            .having('COUNT(campaign_enrollments.id) = 0')
            .find_each do |c|
      CampaignAudienceEnrollerJob.perform_later(c.id)
    end
  end

  def dispatch_due_enrollments
    CampaignEnrollment.due_for_send.find_in_batches(batch_size: 200) do |batch|
      batch.each { |e| ProcessCampaignSendJob.perform_later(e.id) }
    end
  end

  def finalize_completed_campaigns
    Campaign.running.find_each do |c|
      total = c.campaign_enrollments.count
      next if total.zero?
      remaining = c.campaign_enrollments.where(status: %w[pending active]).count
      next if remaining.positive?
      c.update!(status: 'completed', completed_at: Time.current)
      if defined?(WebhookService)
        WebhookService.fire(company_id: c.company_id, event: 'campaign.completed', payload: { campaign_id: c.id })
      end
    end
  end
end
