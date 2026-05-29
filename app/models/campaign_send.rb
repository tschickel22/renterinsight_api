class CampaignSend < ApplicationRecord
  belongs_to :campaign
  belongs_to :campaign_step
  belongs_to :campaign_enrollment
  belongs_to :communication, optional: true
  has_many :campaign_link_tokens, dependent: :destroy

  # Sends that belong to a real (non-test) enrollment. campaign_enrollment_id is NOT NULL,
  # so this subquery exclusion is NULL-safe. Keeps test-send rows out of analytics totals.
  scope :real, -> { where.not(campaign_enrollment_id: CampaignEnrollment.test_sends.select(:id)) }

  # Bridge open/click tracking (recorded against the Communication / TrackedLink) into the
  # campaign analytics columns the stats rollup and timeseries read. opened_at/clicked_at are
  # stamped once (first event); the *_count columns increment on every event.
  def self.record_open_for_communication(communication_id)
    return if communication_id.blank?
    where(communication_id: communication_id)
      .update_all('opened_at = COALESCE(opened_at, NOW()), open_count = open_count + 1')
  end

  def self.record_click_for_communication(communication_id)
    return if communication_id.blank?
    where(communication_id: communication_id)
      .update_all('clicked_at = COALESCE(clicked_at, NOW()), click_count = click_count + 1')
  end
end
