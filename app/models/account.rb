# frozen_string_literal: true
class Account < ApplicationRecord
  include ActivityTrackable
  include Communicable
  include LocationAware
  include NotifiableAccount
  include WebhookNotifiable
  include Reportable
  include WorkflowRunCancellable

  def self.reportable_config
    {
      label: "Accounts",
      category: "crm",
      fields: [
        { key: "id",           label: "ID",          type: "number", filterable: true, sortable: true },
        { key: "name",         label: "Name",        type: "string", filterable: true, sortable: true },
        { key: "email",        label: "Email",       type: "string", filterable: true, sortable: true },
        { key: "phone",        label: "Phone",       type: "string", filterable: true, sortable: false },
        { key: "website",      label: "Website",     type: "string", filterable: true, sortable: false },
        { key: "account_type", label: "Type",        type: "enum",   filterable: true, sortable: true },
        { key: "status",       label: "Status",      type: "enum",   filterable: true, sortable: true },
        { key: "created_at",   label: "Created At",  type: "date",   filterable: true, sortable: true },
        { key: "updated_at",   label: "Updated At",  type: "date",   filterable: true, sortable: true }
      ]
    }
  end

  # Account Types
  ACCOUNT_TYPES = %w[customer prospect vendor partner competitor converted_lead].freeze
  STATUSES = %w[active inactive pending archived].freeze
  RATINGS = %w[hot warm cold].freeze
  OWNERSHIP_TYPES = %w[public private subsidiary other].freeze
  
  # Associations
  belongs_to :company, optional: true

  # ── Duplicate merge ───────────────────────────────────────────────────────
  # merged_into_id is set when this record lost a merge. It keeps the row
  # intact and pointing at its survivor, so the merge is auditable, reversible
  # and old links can be redirected. Every list query must exclude these.
  belongs_to :merged_into, class_name: 'Account', optional: true
  belongs_to :merged_by,   class_name: 'User', optional: true

  # A record that lost a merge must disappear from every list, count, export
  # and report. There are ~200 query sites across leads, contacts and accounts,
  # so filtering at each one guarantees a miss: the first cut of this shipped
  # with the scope defined and never applied, and merged leads kept showing in
  # the CRM list next to the record they had been folded into.
  #
  # default_scope fails closed instead. Everything that has to see a merged
  # record asks for it explicitly through .with_merged.
  default_scope { where(merged_into_id: nil) }

  scope :with_merged, -> { unscope(where: :merged_into_id) }
  scope :not_merged,  -> { where(merged_into_id: nil) }
  scope :merged_away, -> { with_merged.where.not(merged_into_id: nil) }

  def merged? = merged_into_id.present?

  # Follows a chain of merges to the record that is actually live now.
  def surviving_record(depth = 0)
    return self if merged_into_id.blank? || depth > 10

    nxt = self.class.with_merged.find_by(id: merged_into_id)
    nxt ? nxt.surviving_record(depth + 1) : self
  end
  belongs_to :location, optional: true
  belongs_to :source, optional: true
  belongs_to :parent_account, class_name: 'Account', optional: true
  belongs_to :owner, class_name: 'User', optional: true
  
  has_many :sub_accounts, class_name: 'Account', foreign_key: :parent_account_id, dependent: :nullify
  has_many :leads, foreign_key: :converted_account_id, dependent: :nullify
  has_many :deals, dependent: :destroy
  has_many :contacts, dependent: :destroy
  has_many :nurture_enrollments, as: :enrollable, dependent: :destroy
  has_many :lead_activities, through: :leads
  has_many :tag_assignments, as: :entity, class_name: 'TagAssignment', dependent: :destroy
  has_many :tags, through: :tag_assignments
  has_many :activities, class_name: 'AccountActivity', dependent: :destroy
  has_many :quotes, dependent: :destroy
  
  # Owner helper methods (for consistency with other models)
  def owner_user
    owner
  end
  
  def owner_user=(user)
    self.owner = user
  end
  
  # Validations
  validates :name, presence: true, uniqueness: { scope: :company_id }
  validates :email, format: { with: URI::MailTo::EMAIL_REGEXP }, allow_blank: true
  validates :status, inclusion: { in: STATUSES }, allow_blank: true, allow_nil: true  # Many existing accounts don't have status set
  validates :account_type, inclusion: { in: ACCOUNT_TYPES }, allow_blank: true
  validates :rating, inclusion: { in: RATINGS }, allow_blank: true
  validates :ownership, inclusion: { in: OWNERSHIP_TYPES }, allow_blank: true
  validates :website, format: { with: /\Ahttps?:\/\//, message: 'must be a valid URL' }, allow_blank: true, allow_nil: true
  validates :annual_revenue, numericality: { greater_than_or_equal_to: 0 }, allow_blank: true
  validates :employee_count, numericality: { greater_than_or_equal_to: 0, only_integer: true }, allow_blank: true
  
  # Scopes
  scope :active, -> { where(is_deleted: [false, nil]) }  # Don't filter by status - many accounts don't have it set
  scope :customers, -> { where(account_type: 'customer') }
  scope :prospects, -> { where(account_type: 'prospect') }
  scope :converted_leads, -> { where(account_type: 'converted_lead') }
  scope :hot, -> { where(rating: 'hot') }
  scope :warm, -> { where(rating: 'warm') }
  scope :cold, -> { where(rating: 'cold') }
  scope :with_deals, -> { joins(:deals).distinct }
  scope :without_deals, -> { left_joins(:deals).where(deals: { id: nil }) }
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
    deals.where(stage: company.won_stage_keys).sum(:value) || 0
  end

  def open_deals_count
    deals.where.not(stage: company.closed_deal_stage_keys).count
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
  
  # Soft delete functionality
  def soft_delete!
    update_columns(is_deleted: true, deleted_at: Time.current)
  end
  
  def restore!
    update_columns(is_deleted: false, deleted_at: nil)
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
    if website.present?
      self.website = website.downcase.strip
      self.website = "https://#{self.website}" unless self.website =~ /\Ahttps?:\/\//
    end
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

  # ActivityTrackable overrides
  def activity_display_name
    name
  end

  def activity_module_name
    'crm'
  end

  def activity_account_id
    id
  end

  public

  after_commit :emit_workflow_created, on: :create
  after_commit :emit_workflow_updated, on: :update
  after_commit :emit_workflow_deleted, on: :destroy

  private

  def emit_workflow_created
    WorkflowEngine.emit('account.created', self, { id: id })
  end

  def emit_workflow_updated
    changes = saved_changes.keys
    return if changes.blank?
    WorkflowEngine.emit('account.updated', self, { id: id, changes: changes })
    if saved_change_to_attribute?(:status)
      from, to = saved_change_to_attribute(:status)
      WorkflowEngine.emit('account.status_changed', self, { id: id, from: from, to: to })
    end
  end

  def emit_workflow_deleted
    WorkflowEngine.emit('account.deleted', self, { id: id })
  end
end
