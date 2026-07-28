class ProcessCampaignSendJob < ApplicationJob
  queue_as :default
  retry_on StandardError, wait: :polynomially_longer, attempts: 3

  def perform(enrollment_id)
    enrollment = CampaignEnrollment.find_by(id: enrollment_id)
    return unless enrollment
    return unless enrollment.status.in?(%w[pending active])

    # Pausing a campaign must actually stop delivery. CampaignsController#pause
    # only flips campaigns.status — it leaves enrollments 'active' with their
    # next_send_at intact, and CampaignEnrollment.due_for_send never looks at
    # the parent campaign. Without this guard a paused campaign keeps shipping
    # its remaining drip steps on schedule.
    #
    # 'running' is the only status that may send: 'scheduled' campaigns are
    # promoted to running by CampaignSchedulerJob before dispatch (including
    # recurring_digest cycle boundaries), and draft/paused/completed/archived
    # must never deliver.
    #
    # Test sends are unaffected — CampaignsController#test_send calls
    # Campaigns::CampaignSender directly and never enqueues this job, which is
    # what lets an admin test a draft campaign.
    unless enrollment.campaign&.status == 'running'
      Rails.logger.info(
        "[ProcessCampaignSendJob] skipping enrollment #{enrollment.id} — " \
        "campaign #{enrollment.campaign_id} is #{enrollment.campaign&.status.inspect}, not running"
      )
      return
    end

    Campaigns::CampaignSender.new(enrollment: enrollment).deliver_current_step
  end
end
