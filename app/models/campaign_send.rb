class CampaignSend < ApplicationRecord
  belongs_to :campaign
  belongs_to :campaign_step
  belongs_to :campaign_enrollment
  belongs_to :communication, optional: true
  has_many :campaign_link_tokens, dependent: :destroy

  # Sends that belong to a real (non-test) enrollment. campaign_enrollment_id is NOT NULL,
  # so this subquery exclusion is NULL-safe. Keeps test-send rows out of analytics totals.
  scope :real, -> { where.not(campaign_enrollment_id: CampaignEnrollment.test_sends.select(:id)) }
end
