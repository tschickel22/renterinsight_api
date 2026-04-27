class CampaignEnrollment < ApplicationRecord
  STATUSES = %w[pending active completed paused unsubscribed bounced complained goal_met failed].freeze

  belongs_to :campaign
  belongs_to :recipient, polymorphic: true
  has_many :campaign_sends, dependent: :destroy
  has_many :campaign_events

  validates :status, inclusion: { in: STATUSES }
  validates :recipient_id, uniqueness: { scope: [:campaign_id, :recipient_type] }
  validate :contact_snapshot_present

  scope :active, -> { where(status: %w[pending active]) }
  scope :due_for_send, -> { active.where('next_send_at <= ?', Time.current) }

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
      wait_seconds = (next_step.wait_days || 0) * 86400 + (next_step.wait_hours || 0) * 3600
      update!(
        current_step_index: next_index,
        next_send_at: Time.current + wait_seconds.seconds,
        last_sent_at: Time.current
      )
    end
  end
end
