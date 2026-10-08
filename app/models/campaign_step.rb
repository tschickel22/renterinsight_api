class CampaignStep < ApplicationRecord
  CHANNELS = %w[email sms].freeze
  SMS_MAX_LENGTH = 1600  # Twilio long-message hard limit

  # Override the DB default of 'email' so the inherit_channel_from_campaign
  # callback can distinguish "no explicit channel (inherit from campaign)" from
  # "explicit per-step override". Required for mixed-channel drips (Phase E).
  attribute :channel, :string, default: nil

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

  # True when the body is a pasted, fully-designed HTML document (Option A) —
  # rendered as-is by EmailRenderer, bypassing the block layout pipeline.
  def raw_html_step?
    body_blocks.is_a?(Array) &&
      body_blocks.any? { |b| b.is_a?(Hash) && (b['type'] == 'raw_html' || b[:type] == 'raw_html') }
  end

  # A dated step sends on its date and time instead of after a wait. Waits
  # count from when the previous step actually went out, and sends are paced
  # and held to the send window, so "Day 7" drifts by hours per recipient;
  # a message tied to a calendar day (the day of an event) needs a real date.
  def dated? = send_at.present?

  # When this step comes due for someone whose previous step went out at
  # `from`. A dated step ignores its wait.
  def due_at(from = Time.current)
    dated? ? send_at : from + (wait_days || 0).days + (wait_hours || 0).hours
  end

  # Once the step's calendar day is over (in the zone it was picked in) it is
  # skipped, so nobody gets "see you today" the day after.
  def send_day_passed?(now = Time.current)
    dated? && now > send_at.in_time_zone(send_at_zone).end_of_day
  end

  def send_at_zone
    ActiveSupport::TimeZone[send_at_timezone.to_s] || ActiveSupport::TimeZone['Eastern Time (US & Canada)']
  end

  def send_at_label
    send_at&.in_time_zone(send_at_zone)&.strftime('%a, %b %-d, %Y at %-l:%M %p %Z')
  end

  def effective_channel
    return channel if channel.present?
    campaign&.channel
  end

  private

  def inherit_channel_from_campaign
    # Default to the campaign's channel only when the step has no explicit channel.
    # This permits mixed-channel drips (e.g., email step 1, SMS step 2).
    self.channel = campaign&.channel if channel.blank? && campaign
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
    # Raw-HTML steps manage their own unsubscribe via the block's
    # append_unsubscribe toggle (EmailRenderer appends the footer at send time),
    # so don't inject a table-row footer block that would never render there.
    return if raw_html_step?
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
