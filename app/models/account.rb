# frozen_string_literal: true
class Account < ApplicationRecord
  # Account Types
  ACCOUNT_TYPES = %w[customer prospect vendor partner competitor converted_lead].freeze
  STATUSES = %w[active inactive pending archived].freeze
  RATINGS = %w[hot warm cold].freeze
  OWNERSHIP_TYPES = %w[public private subsidiary other].freeze
  
  # Associations
  belongs_to :company, optional: true
  belongs_to :source, optional: true
  belongs_to :parent_account, class_name: 'Account', optional: true
  belongs_to :owner, class_name: 'User', optional: true
  
  has_many :sub_accounts, class_name: 'Account', foreign_key: :parent_account_id, dependent: :nullify
  has_many :leads, foreign_key: :converted_account_id, dependent: :nullify
  has_many :contacts, dependent: :destroy
  has_many :communication_logs, dependent: :destroy
  has_many :nurture_enrollments, as: :enrollable, dependent: :destroy
  
  # Only define deals association if Deal model exists
  if defined?(Deal)
    has_many :deals, dependent: :destroy
  end
  has_many :lead_activities, through: :leads
  has_many :tag_assignments, as: :entity, class_name: 'TagAssignment', dependent: :destroy
  has_many :tags, through: :tag_assignments
  has_many :activities, class_name: 'AccountActivity', dependent: :destroy
  
  # Validations
  validates :name, presence: true, uniqueness: { scope: :company_id }
  validates :email, format: { with: URI::MailTo::EMAIL_REGEXP }, allow_blank: true
  validates :status, inclusion: { in: STATUSES }
  validates :account_type, inclusion: { in: ACCOUNT_TYPES }, allow_blank: true
  validates :rating, inclusion: { in: RATINGS }, allow_blank: true
  validates :ownership, inclusion: { in: OWNERSHIP_TYPES }, allow_blank: true
  validates :website, format: { with: /\Ahttps?:\/\//, message: 'must start with http:// or https://' }, allow_blank: true, allow_nil: true
  validates :annual_revenue, numericality: { greater_than_or_equal_to: 0 }, allow_blank: true
  validates :employee_count, numericality: { greater_than_or_equal_to: 0, only_integer: true }, allow_blank: true
  
  # Scopes
  scope :active, -> { where(status: 'active', is_deleted: false) }
  scope :customers, -> { where(account_type: 'customer') }
  scope :prospects, -> { where(account_type: 'prospect') }
  scope :converted_leads, -> { where(account_type: 'converted_lead') }
  scope :hot, -> { where(rating: 'hot') }
  scope :warm, -> { where(rating: 'warm') }
  scope :cold, -> { where(rating: 'cold') }
  # scope :with_deals, -> { joins(:deals).distinct }
  # scope :without_deals, -> { left_joins(:deals).where(deals: { id: nil }) }
  scope :recently_active, -> { where('accounts.last_activity_date >= ?', 30.days.ago) }
  scope :high_value, -> { where('annual_revenue >= ?', 1_000_000) }
  scope :by_owner, ->(user_id) { where(owner_id: user_id) }
  scope :search, ->(query) { where('name ILIKE ? OR email ILIKE ? OR phone ILIKE ?', "%#{query}%", "%#{query}%", "%#{query}%") }
  
  # Callbacks
  before_validation :normalize_fields
  before_create :generate_account_number
  after_update :update_last_activity_date
  
  # Soft delete
  def soft_delete!
    update!(is_deleted: true, deleted_at: Time.current)
  end
  
  def restore!
    update!(is_deleted: false, deleted_at: nil)
  end
  
  # Business logic
  def convert_to_customer!
    update!(
      account_type: 'customer',
      converted_date: Time.current,
      status: 'active'
    )
  end
  
  def total_deal_value
    return 0 unless defined?(::Deal)
    deals.where(stage: 'closed_won').sum(:amount) || 0
  rescue NameError
    0 # Deal model not available
  end
  
  def open_deals_count
    return 0 unless defined?(::Deal)
    deals.where.not(stage: ['closed_won', 'closed_lost']).count
  rescue NameError
    0 # Deal model not available
  end
  
  def last_activity
    lead_activities.order('lead_activities.created_at DESC').first
  end
  
  def activity_score
    # Calculate activity score based on recent interactions
    recent_activities = lead_activities.where('lead_activities.created_at >= ?', 30.days.ago).count
    case recent_activities
    when 0..2 then 'low'
    when 3..10 then 'medium'
    else 'high'
    end
  end
  
  def activities_count
    activities.count
  end
  
  def last_activity_at
    activities.maximum(:created_at)
  end
  
  def full_address(type = :billing)
    prefix = type.to_s
    [
      send("#{prefix}_street"),
      send("#{prefix}_city"),
      send("#{prefix}_state"),
      send("#{prefix}_postal_code"),
      send("#{prefix}_country")
    ].compact.join(', ')
  end
  
  def as_json(options = {})
    super(options).merge(
      'tags' => tags.pluck(:name),
      'source_name' => source&.name,
      'owner_name' => owner&.name,
      'total_deal_value' => total_deal_value,
      'open_deals_count' => open_deals_count,
      'activity_score' => activity_score
    )
  end
  
  private
  
  def normalize_fields
    self.email = email&.downcase&.strip
    self.website = website&.downcase&.strip if website.present?
    self.phone = phone&.gsub(/\D/, '') if phone.present?
  end
  
  def generate_account_number
    self.account_number ||= loop do
      number = "ACC-#{SecureRandom.hex(4).upcase}"
      break number unless self.class.exists?(account_number: number)
    end
  end
  
  def update_last_activity_date
    self.last_activity_date = Time.current if saved_changes?
  end
end
