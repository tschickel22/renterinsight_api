class Campaign < ApplicationRecord
  STATUSES = %w[draft scheduled running paused completed archived].freeze
  TYPES = %w[blast drip triggered recurring_digest].freeze
  AUDIENCE_MODES = %w[static dynamic].freeze
  IDENTITY_TYPES = %w[User Location Company].freeze

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

  validates :name, :status, :campaign_type, :from_identity_type, presence: true
  validates :status, inclusion: { in: STATUSES }
  validates :campaign_type, inclusion: { in: TYPES }
  validates :audience_mode, inclusion: { in: AUDIENCE_MODES }
  validates :from_identity_type, inclusion: { in: IDENTITY_TYPES }
  validates :throttle_per_day, numericality: { greater_than: 0 }

  scope :active, -> { where(is_deleted: [false, nil]) }
  scope :running, -> { active.where(status: 'running') }
  scope :for_company, ->(cid) { where(company_id: cid) }

  def can_start?
    return false unless status == 'draft'
    return false if campaign_steps.active.empty?
    return false if campaign_audience.nil?
    return false if resolve_email_connection.nil?
    true
  end

  # Resolves to the active email connection for the chosen identity.
  # NEVER falls back to platform — returns nil if no valid connection exists.
  def resolve_email_connection
    case from_identity_type
    when 'User'
      UserEmailConnection.where(user_id: from_identity_id, is_active: true).first
    when 'Location'
      LocationEmailConnection.where(location_id: from_identity_id, is_active: true).first
    when 'Company'
      CompanyEmailConnection.where(company_id: from_identity_id, is_active: true).first
    end
  end
end
