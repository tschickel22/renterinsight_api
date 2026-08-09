class CampaignSend < ApplicationRecord
  belongs_to :campaign
  belongs_to :campaign_step
  belongs_to :campaign_enrollment
  belongs_to :communication, optional: true
  has_many :campaign_link_tokens, dependent: :destroy

  # Sends that belong to a real (non-test) enrollment. campaign_enrollment_id is NOT NULL,
  # so this subquery exclusion is NULL-safe. Keeps test-send rows out of analytics totals.
  scope :real, -> { where.not(campaign_enrollment_id: CampaignEnrollment.test_sends.select(:id)) }

  # Delivery that actually held. A receiving server can accept a message at SMTP time and
  # reject it moments later, which produces a Delivery event AND then a Bounce event for the
  # same send. Counting delivered_at on its own therefore reported those as both delivered
  # and bounced, overstating the delivery rate by exactly the async-bounce count — on the
  # first SES campaign that was 3 of 52, every one of them a hard bounce.
  scope :delivered, -> { where.not(delivered_at: nil).where(bounced_at: nil) }

  # Bridge open/click tracking (recorded against the Communication / TrackedLink) into the
  # campaign analytics columns the stats rollup and timeseries read. opened_at/clicked_at are
  # stamped once (first event); the *_count columns increment on every event.
  def self.record_open_for_communication(communication_id)
    return if communication_id.blank?
    where(communication_id: communication_id)
      .update_all('opened_at = COALESCE(opened_at, NOW()), open_count = open_count + 1')
  end

  # A click implies an open: the recipient must have opened the email to click a link.
  # Open pixels are frequently blocked by mail clients, so without this a clicked email
  # could show 0 opens. Stamp opened_at if not already set (open_count to at least 1).
  def self.record_click_for_communication(communication_id)
    return if communication_id.blank?
    where(communication_id: communication_id).update_all(
      'clicked_at = COALESCE(clicked_at, NOW()), click_count = click_count + 1, ' \
      'opened_at = COALESCE(opened_at, NOW()), open_count = GREATEST(open_count, 1)'
    )
  end
end
