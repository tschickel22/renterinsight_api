class CampaignStep < ApplicationRecord
  CHANNELS = %w[email sms].freeze
  SMS_MAX_LENGTH = 1600  # Twilio long-message hard limit

  belongs_to :campaign

  validates :position, presence: true, numericality: { greater_than_or_equal_to: 0 }
  validates :wait_days, numericality: { greater_than_or_equal_to: 0 }
  validates :wait_hours, numericality: { greater_than_or_equal_to: 0, less_than_or_equal_to: 23 }
  validates :channel, inclusion: { in: CHANNELS }, allow_nil: true

  validate :sms_body_present_when_sms
  validate :sms_body_length_within_limit
  validate :no_inventory_block_for_sms

  scope :active, -> { where(is_active: true) }
  scope :ordered, -> { order(:position) }

  before_validation :inherit_channel_from_campaign
  before_save :ensure_footer_unsubscribe   # email channel only
  before_save :ensure_sms_stop_footer      # sms channel only

  def email_channel? = effective_channel == 'email'
  def sms_channel?   = effective_channel == 'sms'

  def effective_channel
    return channel if channel.present?
    campaign&.channel
  end

  private

  def inherit_channel_from_campaign
    # Steps always match the parent campaign's channel. The DB default of
    # 'email' kicks in for new records, so we overwrite here at validation time.
    self.channel = campaign.channel if campaign
  end

  def sms_body_present_when_sms
    return unless sms_channel?
    errors.add(:sms_body, 'must be present for SMS campaign steps') if sms_body.blank?
  end

  def sms_body_length_within_limit
    return unless sms_channel? && sms_body.present?
    if sms_body.length > SMS_MAX_LENGTH
      errors.add(:sms_body, "must be #{SMS_MAX_LENGTH} characters or fewer (currently #{sms_body.length})")
    end
  end

  def no_inventory_block_for_sms
    return unless sms_channel?
    if inventory_block_config.present?
      errors.add(:inventory_block_config, 'cannot be used with SMS channel; use email channel for inventory merges')
    end
  end

  def ensure_footer_unsubscribe
    return unless email_channel?
    return if body_blocks.blank?
    return unless body_blocks.is_a?(Array)
    has_footer = body_blocks.any? { |b| b.is_a?(Hash) && (b['type'] == 'footer_unsubscribe' || b[:type] == 'footer_unsubscribe') }
    self.body_blocks = body_blocks + [{ 'type' => 'footer_unsubscribe' }] unless has_footer
  end

  def ensure_sms_stop_footer
    return unless sms_channel?
    return if sms_body.blank?
    return if sms_body.match?(/\b(reply\s+stop|text\s+stop|stop\s+to\s+(opt|unsubscribe|cancel))/i)

    suffix = "\n\nReply STOP to unsubscribe"
    if sms_body.length + suffix.length > SMS_MAX_LENGTH
      errors.add(:sms_body, "leaves no room for the required 'Reply STOP to unsubscribe' footer (need #{suffix.length} more chars)")
      return
    end
    self.sms_body = sms_body + suffix
  end
end
