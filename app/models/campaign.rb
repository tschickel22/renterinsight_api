require 'ostruct'

class Campaign < ApplicationRecord
  STATUSES = %w[draft scheduled running paused completed archived].freeze
  TYPES = %w[blast drip triggered recurring_digest].freeze
  AUDIENCE_MODES = %w[static dynamic].freeze
  IDENTITY_TYPES = %w[User Location Company].freeze
  CHANNELS = %w[email sms].freeze

  belongs_to :company
  belongs_to :location, optional: true
  belongs_to :created_by, class_name: 'User', foreign_key: :created_by_user_id
  belongs_to :from_identity, polymorphic: true
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

  scope :active, -> { where(is_deleted: [false, nil]) }
  scope :running, -> { active.where(status: 'running') }
  scope :for_company, ->(cid) { where(company_id: cid) }
  scope :email_channel, -> { where(channel: 'email') }
  scope :sms_channel, -> { where(channel: 'sms') }

  before_validation :enforce_sms_identity_constraints

  def email_channel? = channel == 'email'
  def sms_channel?   = channel == 'sms'

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
      return false if resolve_email_connection_for_step.nil?
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
  # NEVER falls back to platform-level senders.
  def resolve_email_connection_for_step
    case from_identity_type
    when 'User'
      UserEmailConnection.where(company_id: company_id, user_id: from_identity_id, is_active: true).first
    when 'Location'
      LocationEmailConnection.where(company_id: company_id, location_id: from_identity_id, is_active: true).first
    when 'Company'
      CompanyEmailConnection.where(company_id: company_id, is_active: true).first
    end
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
