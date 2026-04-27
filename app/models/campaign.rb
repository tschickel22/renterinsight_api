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

  def can_start?
    return false unless status == 'draft'
    return false if campaign_steps.active.empty?
    return false if campaign_audience.nil?
    if email_channel?
      return false if resolve_email_connection.nil?
    elsif sms_channel?
      return false if resolve_sms_sender.nil?
    end
    true
  end

  # Email connection resolution — NEVER falls back to platform.
  def resolve_email_connection
    return nil if sms_channel?
    case from_identity_type
    when 'User'
      UserEmailConnection.where(user_id: from_identity_id, is_active: true).first
    when 'Location'
      LocationEmailConnection.where(location_id: from_identity_id, is_active: true).first
    when 'Company'
      CompanyEmailConnection.where(company_id: from_identity_id, is_active: true).first
    end
  end

  # SMS sender resolution — NEVER falls back to master account.
  # Prefers location-specific number when campaign has location_id and a
  # matching TwilioAccount exists; otherwise company-wide; else nil.
  def resolve_sms_sender
    return nil unless sms_channel?

    if location_id.present?
      loc_match = TwilioAccount.where(company_id: company_id, location_id: location_id, status: 'active').first
      return loc_match if loc_match
    end

    TwilioAccount.where(company_id: company_id, location_id: nil, status: 'active').first
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
