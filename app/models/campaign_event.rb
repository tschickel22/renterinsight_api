class CampaignEvent < ApplicationRecord
  EVENT_TYPES = %w[enrolled unenrolled step_scheduled step_skipped goal_met paused resumed failed compliance_acknowledgment sms_stop sms_help sms_start bounced_async auto_reply_received].freeze

  belongs_to :campaign
  belongs_to :campaign_enrollment, optional: true
  belongs_to :campaign_send, optional: true

  validates :event_type, inclusion: { in: EVENT_TYPES }
  validates :occurred_at, presence: true

  scope :recent, -> { order(occurred_at: :desc) }
end
