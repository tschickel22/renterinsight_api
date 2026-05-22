# frozen_string_literal: true

class Contact < ApplicationRecord
  include ActivityTrackable
  include LocationAware
  include NotifiableContact
  include WebhookNotifiable
  include Reportable
  include WorkflowRunCancellable

  def self.reportable_config
    {
      label: "Contacts",
      category: "crm",
      fields: [
        { key: "id",         label: "ID",         type: "number", filterable: true, sortable: true },
        { key: "first_name", label: "First Name", type: "string", filterable: true, sortable: true },
        { key: "last_name",  label: "Last Name",  type: "string", filterable: true, sortable: true },
        { key: "email",      label: "Email",      type: "string", filterable: true, sortable: true },
        { key: "phone",      label: "Phone",      type: "string", filterable: true, sortable: false },
        { key: "title",      label: "Title",      type: "string", filterable: true, sortable: true },
        { key: "account_id", label: "Account",    type: "number", filterable: true, sortable: true },
        { key: "created_at", label: "Created At", type: "date",   filterable: true, sortable: true },
        { key: "updated_at", label: "Updated At", type: "date",   filterable: true, sortable: true }
      ]
    }
  end

  # Associations
  belongs_to :account, optional: true
  belongs_to :company, optional: true
  belongs_to :location, optional: true
  belongs_to :owner, class_name: 'User', foreign_key: 'owner_id', optional: true
  belongs_to :preferred_vehicle, class_name: 'Vehicle', foreign_key: 'preferred_vehicle_id', optional: true
  has_many :tracked_links, as: :entity, dependent: :destroy
  has_many :tag_assignments, as: :entity, dependent: :destroy
  has_many :tags, through: :tag_assignments
  has_many :note_records, class_name: 'Note', as: :entity, dependent: :destroy
  has_many :quotes, dependent: :destroy
  has_many :invoices, dependent: :destroy
  has_many :loans, as: :borrower, dependent: :destroy
  has_many :payments, as: :payable, dependent: :destroy
  has_many :communications, as: :communicable, dependent: :destroy
  has_many :contact_activities, dependent: :destroy
  has_many :portal_documents, as: :owner, dependent: :destroy
  has_many :nurture_enrollments, as: :enrollable, dependent: :destroy
  has_many :deals, dependent: :nullify
  has_many :agreement_signers, as: :signable, dependent: :nullify
  has_many :agreement_attachments, as: :attachable, dependent: :destroy

  # Owner helper methods
  def owner_user
    owner
  end
  
  def owner_user=(user)
    self.owner = user
  end

  # Validations
  validates :first_name, presence: true
  validates :email, format: { with: URI::MailTo::EMAIL_REGEXP, allow_blank: true }
  validates :phone, format: { with: /\A[\d\s\-\(\)\+\.]+\z/, allow_blank: true }

  # Scopes
  scope :primary, -> { where(is_primary: true) }
  scope :with_email, -> { where.not(email: nil).where.not(email: '') }
  scope :with_phone, -> { where.not(phone: nil).where.not(phone: '') }
  scope :by_department, ->(dept) { where(department: dept) }
  scope :by_title, ->(title) { where(title: title) }
  scope :recent, -> { order(created_at: :desc) }
  scope :updated_recently, -> { order(updated_at: :desc) }

  # Callbacks
  before_validation :normalize_email
  before_validation :normalize_phone

  # Instance methods
  def full_name
    [first_name, last_name].compact.join(' ')
  end
  
  def name
    full_name
  end

  def display_name
    full_name.presence || email || phone || 'Unnamed Contact'
  end

  def has_contact_info?
    email.present? || phone.present?
  end

  def contact_methods
    methods = []
    methods << 'email' if email.present? && !opt_out_email?
    methods << 'phone' if phone.present? && !opt_out_sms?
    methods
  end

  # Opt-out methods
  def opt_out_email?
    opt_out_email == true
  end

  def opt_out_sms?
    opt_out_sms == true
  end

  def can_email?
    email.present? && !opt_out_email?
  end

  def can_sms?
    phone.present? && !opt_out_sms?
  end

  def opt_in_email!
    update(opt_out_email: false, opt_out_email_at: nil)
  end

  def opt_in_sms!
    update(opt_out_sms: false, opt_out_sms_at: nil)
  end

  def opt_out_email!(reason = nil)
    update(opt_out_email: true, opt_out_email_at: Time.current)
  end

  def opt_out_sms!(reason = nil)
    update(opt_out_sms: true, opt_out_sms_at: Time.current)
  end

  # Search functionality
  def self.search(query)
    return all if query.blank?

    query = query.downcase
    where(
      'LOWER(first_name) LIKE ? OR LOWER(last_name) LIKE ? OR LOWER(email) LIKE ? OR LOWER(phone) LIKE ? OR LOWER(title) LIKE ? OR LOWER(department) LIKE ?',
      "%#{query}%", "%#{query}%", "%#{query}%", "%#{query}%", "%#{query}%", "%#{query}%"
    )
  end

  # Statistics
  def self.statistics
    {
      total: count,
      with_email: with_email.count,
      with_phone: with_phone.count,
      primary: primary.count,
      by_department: group(:department).count,
      by_title: group(:title).count,
      recent_count: where('created_at >= ?', 30.days.ago).count
    }
  end

  after_commit :emit_workflow_created, on: :create
  after_commit :emit_workflow_updated, on: :update
  after_commit :emit_workflow_deleted, on: :destroy

  private

  def emit_workflow_created
    WorkflowEngine.emit('contact.created', self, { id: id })
  end

  def emit_workflow_updated
    WorkflowEngine.emit('contact.updated', self, { id: id, changes: saved_changes.keys })
  end

  def emit_workflow_deleted
    WorkflowEngine.emit('contact.deleted', self, { id: id })
  end

  def normalize_email
    self.email = email.to_s.strip.downcase if email.present?
  end

  def normalize_phone
    self.phone = phone.to_s.strip if phone.present?
  end

  # ActivityTrackable overrides
  def activity_display_name
    try(:full_name).presence || try(:display_name).presence || "#{first_name} #{last_name}".strip.presence || "Contact ##{id}"
  end

  def activity_module_name
    'crm'
  end

  def activity_account_id
    account_id
  end
end
