class ProcessCampaignSendJob < ApplicationJob
  queue_as :default
  retry_on StandardError, wait: :polynomially_longer, attempts: 3

  def perform(enrollment_id)
    enrollment = CampaignEnrollment.find_by(id: enrollment_id)
    return unless enrollment
    return unless enrollment.status.in?(%w[pending active])
    Campaigns::CampaignSender.new(enrollment: enrollment).deliver_current_step
  end
end
