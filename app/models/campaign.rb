require 'ostruct'

class Campaign < ApplicationRecord
  STATUSES = %w[draft scheduled running paused completed archived].freeze
  TYPES = %w[blast drip triggered recurring_digest].freeze
  AUDIENCE_MODES = %w[static dynamic].freeze
  # 'Owner' resolves per-recipient at send time — the sender for each
  # enrollment is that recipient's owner (Lead#owner / Contact#owner /
  # Account#owner). Lets a rep author a campaign that other reps can
  # subscribe their own leads/contacts to and the from-address stays
  # authentic. Owner-mode campaigns leave from_identity_id NULL.
  IDENTITY_TYPES = %w[User Location Company Owner].freeze
  CHANNELS = %w[email sms].freeze

  belongs_to :company
  belongs_to :location, optional: true
  belongs_to :created_by, class_name: 'User', foreign_key: :created_by_user_id
  belongs_to :from_identity, polymorphic: true, optional: true
  belongs_to :seeded_from_template, class_name: 'CampaignTemplate', optional: true
  belongs_to :generated_from_ai_generation, class_name: 'CampaignAiGeneration', optional: true

  has_many :campaign_steps, -> { order(:position) }, dependent: :destroy
  has_one :campaign_audience, dependent: :destroy
  has_many :campaign_enrollments, dependent: :destroy
  has_many :campaign_sends, dependent: :destroy
  has_many :campaign_events, dependent: :destroy

  validates :name, :status, :campaign_type, :from_identity_type, :channel, presence: true
  validates :status, inclusion: { in: STATUSES }
  validates :campaign_type, inclusion: { in: TYPES }
  validates :audience_mode, inclusion: { in: AUDIENCE_MODES }
  validates :from_identity_type, inclusion: { in: IDENTITY_TYPES }
  validates :channel, inclusion: { in: CHANNELS }
  validates :throttle_per_day, numericality: { greater_than: 0 }
  # Owner mode has no fixed identity id — the sender is resolved per
  # recipient at send time. Every other identity type requires an id.
  validates :from_identity_id, presence: true, unless: :owner_identity?

  def owner_identity?
    from_identity_type == 'Owner'
  end

  scope :active, -> { where(is_deleted: [false, nil]) }
  scope :running, -> { active.where(status: 'running') }
  scope :for_company, ->(cid) { where(company_id: cid) }
  scope :email_channel, -> { where(channel: 'email') }
  scope :sms_channel, -> { where(channel: 'sms') }

  before_validation :enforce_sms_identity_constraints

  def email_channel? = channel == 'email'
  def sms_channel?   = channel == 'sms'

  # True when this campaign is meant to cycle on a cron cadence (weekly
  # newsletter, monthly digest, etc.) instead of finalizing after one pass.
  # CampaignSchedulerJob keys off this to reset the campaign back to
  # 'scheduled' at each cycle boundary rather than marking it 'completed'.
  def recurring?
    campaign_type == 'recurring_digest' && recurrence_cron.present?
  end

  # Next fire time for the cron expression. Uses Fugit (already in the
  # bundle via sidekiq-cron) so we parse the same 5-field format everyone
  # writes. Returns nil for a blank/invalid expression so callers can
  # decide whether to treat that as "finalize" or "leave running".
  #
  # Evaluated in the company's configured time zone so "9:00 AM MON" means
  # 9 AM in the dealer's local time, not UTC. Falls back to Eastern via
  # Company#time_zone if operational_settings.timezone is unset. Returned
  # value is normalized back to UTC for DB storage.
  def next_recurrence_at(from = Time.current)
    return nil if recurrence_cron.blank?
    parsed = ::Fugit.parse(recurrence_cron.to_s)
    return nil if parsed.nil?
    tz = company&.time_zone.presence || 'America/New_York'
    Time.use_zone(tz) do
      parsed.next_time(from.in_time_zone(tz))&.to_utc_time
    end
  rescue StandardError => e
    Rails.logger.warn "[Campaign##{id}] recurrence_cron parse failed: #{e.class}: #{e.message}"
    nil
  end

  def mixed_channel?
    step_channels = campaign_steps.pluck(:channel).compact.uniq
    step_channels.length > 1
  end

  def can_start?
    return false unless status == 'draft'
    return false if campaign_steps.active.empty?
    return false if campaign_audience.nil?

    step_channels = campaign_steps.active.pluck(:channel).compact.uniq
    if step_channels.include?('email') || (step_channels.empty? && email_channel?)
      # Owner mode defers resolution to send time (per-recipient), so we
      # can't preflight a single connection here. Allow start; the sender
      # gates each individual send instead.
      return false unless owner_identity? || !resolve_email_connection_for_step.nil?
    end
    if step_channels.include?('sms') || (step_channels.empty? && sms_channel?)
      return false if resolve_sms_sender_for_step.nil?
    end
    true
  end

  # Email connection resolution — NEVER falls back to platform.
  # All lookups MUST be scoped to self.company_id to prevent cross-tenant leaks.
  def resolve_email_connection
    return nil if sms_channel?
    case from_identity_type
    when 'User'
      UserEmailConnection.where(company_id: company_id, user_id: from_identity_id, is_active: true).first
    when 'Location'
      LocationEmailConnection.where(company_id: company_id, location_id: from_identity_id, is_active: true).first
    when 'Company'
      CompanyEmailConnection.where(company_id: company_id, is_active: true).first
    end
  end

  # SMS sender resolution — NEVER falls back to master account.
  # Prefers location-specific number when campaign has location_id and a
  # matching TwilioAccount exists; otherwise company-wide; else falls back to
  # the CommunicationSettings waterfall (Location → Company → Platform) for
  # companies whose Twilio is configured via settings rather than a
  # TwilioAccount row. Returns nil if no usable sender is configured anywhere.
  def resolve_sms_sender
    return nil unless sms_channel?

    if location_id.present?
      loc_match = TwilioAccount.where(company_id: company_id, location_id: location_id, status: 'active').first
      return loc_match if loc_match
    end

    twilio_acct = TwilioAccount.where(company_id: company_id, location_id: nil, status: 'active').first
    return twilio_acct if twilio_acct

    sms_cfg = CommunicationSettingsService.for_company(Company.find(company_id)).sms_config
    if sms_cfg[:enabled] && sms_cfg[:from_number].present?
      OpenStruct.new(phone_number: sms_cfg[:from_number])
    end
  end

  # Step-level email resolver — bypasses campaign-channel guard for mixed-channel
  # drips. Used by CampaignSender#deliver_email when sending an individual step
  # whose channel may differ from the campaign's primary channel.
  # Queries the same company-scoped OAuth connection tables as resolve_email_connection.
  # NEVER falls back to platform-level senders — the caller (CampaignSender)
  # gates on a nil return so campaigns can't leak through platform SES.
  #
  # `recipient` is required for Owner-mode campaigns: the sender resolves to
  # THIS recipient's owner (Lead#owner / Contact#owner / Account#owner) so a
  # shared campaign can send from each recipient's real rep. When Owner mode
  # is set but the recipient has no owner or the owner has no verified email
  # connection, returns nil — the caller marks the send as failed and moves
  # on rather than silently downgrading to a company-scoped or platform sender.
  def resolve_email_connection_for_step(recipient: nil)
    case from_identity_type
    when 'User'
      UserEmailConnection.where(company_id: company_id, user_id: from_identity_id, is_active: true).first
    when 'Location'
      LocationEmailConnection.where(company_id: company_id, location_id: from_identity_id, is_active: true).first
    when 'Company'
      CompanyEmailConnection.where(company_id: company_id, is_active: true).first
    when 'Owner'
      resolve_owner_email_connection(recipient)
    end
  end

  # Look up the recipient's owner and their active email connection. Kept
  # in one place so both the send path and the "can this campaign start?"
  # preflight speak the same rule.
  def resolve_owner_email_connection(recipient)
    return nil unless recipient
    owner_id = recipient.try(:owner_id) || recipient.try(:owner)&.id
    return nil if owner_id.blank?
    UserEmailConnection.where(company_id: company_id, user_id: owner_id, is_active: true).first
  end

  # Stable identifier for the mailbox a send goes out through, e.g.
  # "UserEmailConnection:35". Send rate limits are counted against this rather
  # than against the campaign, because two campaigns pointed at one mailbox have
  # to share its budget. Owner-mode campaigns resolve a different mailbox per
  # recipient, which is why this takes the recipient rather than reading the
  # campaign's from_identity_* columns.
  def sending_connection_key(recipient: nil)
    return nil unless email_channel?
    self.class.connection_key_for(resolve_email_connection_for_step(recipient: recipient))
  end

  def self.connection_key_for(connection)
    return nil if connection.nil?
    "#{connection.class.name}:#{connection.id}"
  end

  # Step-level SMS resolver — bypasses campaign-channel guard for mixed-channel
  # drips. Used by CampaignSender#deliver_sms when sending an individual step.
  # Always queries company-scoped TwilioAccount (SMS identity is always Company-level,
  # enforced by enforce_sms_identity_constraints). NEVER falls back to master account.
  def resolve_sms_sender_for_step
    if location_id.present?
      loc_match = TwilioAccount.where(company_id: company_id, location_id: location_id, status: 'active').first
      return loc_match if loc_match
    end

    twilio_acct = TwilioAccount.where(company_id: company_id, location_id: nil, status: 'active').first
    return twilio_acct if twilio_acct

    sms_cfg = CommunicationSettingsService.for_company(Company.find(company_id)).sms_config
    if sms_cfg[:enabled] && sms_cfg[:from_number].present?
      OpenStruct.new(phone_number: sms_cfg[:from_number])
    end
  end

  private

  # SMS campaigns must always send from the company itself —
  # User and Location identity types don't make sense (numbers belong to
  # companies, not people). If channel=sms, force from_identity to Company.
  def enforce_sms_identity_constraints
    return unless sms_channel?
    self.from_identity_type = 'Company'
    self.from_identity_id = company_id
  end
end
