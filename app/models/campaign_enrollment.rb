class CampaignEnrollment < ApplicationRecord
  STATUSES = %w[pending active completed paused unsubscribed bounced complained goal_met failed].freeze

  belongs_to :campaign
  belongs_to :recipient, polymorphic: true
  has_many :campaign_sends, dependent: :destroy
  has_many :campaign_events

  validates :status, inclusion: { in: STATUSES }
  validates :recipient_id, uniqueness: { scope: [:campaign_id, :recipient_type] }
  validate :contact_snapshot_present

  # Every unsubscribe that names an enrollment (the unsubscribe page, SMS STOP,
  # a carrier opt-out, a spam complaint) goes through update!, so a callback
  # sees it. The sweep that also unsubscribes the person's other campaigns uses
  # update_all on purpose: one unsubscribe should start one workflow, not one
  # per campaign.
  after_update_commit :emit_unsubscribe_to_workflows,
                      if: -> { saved_change_to_status? && status == 'unsubscribed' }
  # Both ways an enrollment finishes (the last step sent, or the sender finding
  # no step left) save status 'completed' with update!, so this sees each one.
  after_update_commit :fire_enrollment_completed_webhook,
                      if: -> { saved_change_to_status? && status == 'completed' }

  scope :active, -> { where(status: %w[pending active]) }
  # Only enrollments whose parent campaign is actually running are due. Without
  # the join, pausing a campaign doesn't stop delivery — pause flips
  # campaigns.status but leaves enrollments 'active' with next_send_at intact,
  # so the scheduler keeps shipping the remaining drip steps on schedule.
  # ProcessCampaignSendJob re-checks the same condition (that's the
  # safety-critical guard — jobs can already be sitting in the queue when a
  # pause lands); this scope stops the scheduler enqueuing no-ops at all.
  scope :due_for_send, lambda {
    active
      .joins(:campaign)
      .where(campaigns: { status: 'running' })
      .where('campaign_enrollments.next_send_at <= ?', Time.current)
  }

  # Test sends (CampaignsController#test_send) create a real enrollment with this metadata
  # flag so the sender pipeline works. They must be excluded from analytics and recipient
  # lists so they don't inflate "sent" counts or show the admin as a campaign recipient.
  scope :test_sends, -> { where("metadata->>'test_send' = 'true'") }
  scope :real, -> { where("metadata->>'test_send' IS DISTINCT FROM 'true'") }

  def contact_snapshot_present
    if email_address_snapshot.blank? && sms_phone_snapshot.blank?
      errors.add(:base, 'Either email_address_snapshot or sms_phone_snapshot must be present')
    end
  end

  def advance_to_next_step
    next_index = current_step_index + 1
    next_step = campaign.campaign_steps.active.ordered.offset(next_index).first
    if next_step.nil?
      update!(status: 'completed', last_sent_at: Time.current)
    else
      # Paced like the initial enrollment, otherwise a cohort enrolled together
      # re-converges on the next step: 490 recipients that were spread over an
      # hour would all come due at exactly wait_days later and burst again.
      # A dated step comes due at its date rather than after a wait.
      slot = Messaging::SendPacer.new(
        connection_key: sending_connection_key,
        earliest: next_step.due_at(Time.current)
      ).next_slot
      update!(
        status: 'active', # in-progress drip (was 'pending'); stays in the active scope
        current_step_index: next_index,
        next_send_at: slot,
        last_sent_at: Time.current
      )
    end
  end

  private

  def emit_unsubscribe_to_workflows
    Campaigns::WorkflowBridge.emit(:unsubscribed, enrollment: self)
  end

  def fire_enrollment_completed_webhook
    return if metadata.is_a?(Hash) && metadata['test_send'].to_s == 'true'

    WebhookService.fire(
      company_id: company_id,
      event: 'campaign.enrollment_completed',
      payload: { campaign_id: campaign_id, enrollment_id: id,
                 recipient_type: recipient_type, recipient_id: recipient_id }
    )
  rescue => e
    Rails.logger.error("[CampaignEnrollment] enrollment_completed webhook failed: #{e.message}")
  end
end
