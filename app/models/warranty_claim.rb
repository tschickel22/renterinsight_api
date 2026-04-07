# frozen_string_literal: true

# == Schema Information
#
# Table name: warranty_claims
#
#  id                         :bigint           not null, primary key
#  company_id                 :bigint           not null
#  location_id                :bigint
#  service_ticket_id          :bigint           not null
#  manufacturer_id            :bigint           not null
#  claim_number               :string           not null
#  manufacturer_claim_number  :string
#  estimated_amount           :decimal(10, 2)
#  approved_amount            :decimal(10, 2)
#  client_copay_amount        :decimal(10, 2)   default(0.0)
#  parts                      :jsonb            default([])
#  labor                      :jsonb            default([])
#  status                     :string           default("draft"), not null
#  submitted_at               :datetime
#  manufacturer_responded_at  :datetime
#  approved_at                :datetime
#  denied_at                  :datetime
#  closed_at                  :datetime
#  notes_internal             :text
#  notes_to_manufacturer      :text
#  manufacturer_response      :text
#  denial_reason              :text
#  public_token               :string           not null
#  views_count                :integer          default(0)
#  submitted_by               :string
#  approved_by                :string
#  is_deleted                 :boolean          default(FALSE), not null
#  deleted_at                 :datetime
#  created_at                 :datetime         not null
#  updated_at                 :datetime         not null
#

class WarrantyClaim < ApplicationRecord
  include LocationAware
  include NotifiableWarrantyClaim
  include Reportable

  def self.reportable_config
    {
      label: "Warranty Claims",
      category: "operations",
      fields: [
        { key: "id",                        label: "ID",               type: "number",  filterable: true,  sortable: true  },
        { key: "claim_number",              label: "Claim Number",     type: "string",  filterable: true,  sortable: true  },
        { key: "manufacturer_claim_number", label: "Mfr Claim Number", type: "string",  filterable: true,  sortable: true  },
        { key: "status",                    label: "Status",           type: "enum",    filterable: true,  sortable: true  },
        { key: "manufacturer_id",           label: "Manufacturer",     type: "number",  filterable: true,  sortable: true  },
        { key: "service_ticket_id",         label: "Service Ticket",   type: "number",  filterable: true,  sortable: true  },
        { key: "estimated_amount",          label: "Estimated Amount", type: "number",  filterable: true,  sortable: true  },
        { key: "approved_amount",           label: "Approved Amount",  type: "number",  filterable: true,  sortable: true  },
        { key: "client_copay_amount",       label: "Client Copay",     type: "number",  filterable: true,  sortable: true  },
        { key: "submitted_by",              label: "Submitted By",     type: "string",  filterable: true,  sortable: false },
        { key: "submitted_at",              label: "Submitted At",     type: "date",    filterable: true,  sortable: true  },
        { key: "approved_at",               label: "Approved At",      type: "date",    filterable: true,  sortable: true  },
        { key: "denied_at",                 label: "Denied At",        type: "date",    filterable: true,  sortable: true  },
        { key: "closed_at",                 label: "Closed At",        type: "date",    filterable: true,  sortable: true  },
        { key: "denial_reason",             label: "Denial Reason",    type: "string",  filterable: false, sortable: false },
        { key: "notes_internal",            label: "Internal Notes",   type: "string",  filterable: false, sortable: false },
        { key: "created_at",                label: "Created At",       type: "date",    filterable: true,  sortable: true  },
        { key: "updated_at",                label: "Updated At",       type: "date",    filterable: true,  sortable: true  }
      ]
    }
  end
  
  STATUSES = %w[
    draft 
    submitted 
    under_review 
    approved 
    denied 
    short_paid 
    resubmitted 
    closed
  ].freeze
  
  # Associations
  belongs_to :company
  belongs_to :location, optional: true
  belongs_to :service_ticket
  belongs_to :manufacturer
  belongs_to :owner, class_name: 'User', foreign_key: 'owner_id', optional: true
  has_one :manufacturer_ar_transaction, dependent: :destroy
  has_many :manufacturer_claim_views, dependent: :destroy
  
  # Active Storage for attachments (photos, docs, remittance)
  has_many_attached :attachments
  
  # Validations
  validates :claim_number, presence: true, uniqueness: { scope: :company_id }
  validates :status, presence: true, inclusion: { in: STATUSES }
  validates :public_token, presence: true, uniqueness: true
  validates :estimated_amount, numericality: { greater_than_or_equal_to: 0 }, allow_nil: true
  validates :approved_amount, numericality: { greater_than_or_equal_to: 0 }, allow_nil: true
  validates :client_copay_amount, numericality: { greater_than_or_equal_to: 0 }, allow_nil: true
  
  # Serialize JSONB columns
  attribute :parts, :json, default: []
  attribute :labor, :json, default: []
  
  # Scopes
  scope :active, -> { where(is_deleted: false) }
  scope :by_status, ->(status) { where(status: status) }
  scope :draft, -> { where(status: 'draft') }
  scope :submitted, -> { where(status: 'submitted') }
  scope :under_review, -> { where(status: 'under_review') }
  scope :approved, -> { where(status: 'approved') }
  scope :denied, -> { where(status: 'denied') }
  scope :pending, -> { where(status: ['submitted', 'under_review', 'resubmitted']) }
  scope :closed, -> { where(status: 'closed') }
  scope :recent, -> { order(created_at: :desc) }
  scope :by_manufacturer, ->(manufacturer_id) { where(manufacturer_id: manufacturer_id) }
  scope :for_service_ticket, ->(ticket_id) { where(service_ticket_id: ticket_id) }
  
  # Owner helper methods
  def owner_user
    owner
  end
  
  def owner_user=(user)
    self.owner = user
  end
  
  # Callbacks
  before_validation :set_owner_from_service_ticket, on: :create
  before_validation :generate_claim_number, on: :create
  before_validation :generate_public_token, on: :create
  after_update :create_ar_transaction_if_approved
  after_update :notify_company_of_response, if: :saved_change_to_manufacturer_responded_at?
  
  # Status Checks
  def draft?
    status == 'draft'
  end
  
  def submitted?
    status == 'submitted'
  end
  
  def under_review?
    status == 'under_review'
  end
  
  def approved?
    status == 'approved'
  end
  
  def denied?
    status == 'denied'
  end
  
  def closed?
    status == 'closed'
  end
  
  def pending?
    ['submitted', 'under_review', 'resubmitted'].include?(status)
  end
  
  def can_be_submitted?
    draft? && parts.present? && manufacturer_id.present?
  end
  
  def can_be_resubmitted?
    # Allow resubmission for any submitted claim except draft and closed
    # Use case: Manufacturer says they didn't receive the email
    !draft? && !closed?
  end
  
  # Status Transitions
  def submit!(submitted_by_user)
    return false unless can_be_submitted?
    
    update!(
      status: 'submitted',
      submitted_at: Time.current,
      submitted_by: submitted_by_user
    )
    
    # Send email to manufacturer
    send_manufacturer_notification
    
    true
  end
  
  def mark_under_review!
    return false unless submitted?
    
    update!(
      status: 'under_review',
      manufacturer_responded_at: Time.current
    )
  end
  
  def approve!(approved_amount_value, response_text = nil)
    update!(
      status: 'approved',
      approved_amount: approved_amount_value,
      manufacturer_response: response_text,
      manufacturer_responded_at: Time.current,
      approved_at: Time.current
    )
    
    # AR transaction will be created by callback
    true
  end
  
  def deny!(denial_reason_text)
    update!(
      status: 'denied',
      denial_reason: denial_reason_text,
      manufacturer_responded_at: Time.current,
      denied_at: Time.current
    )
  end
  
  def resubmit!(resubmitted_by_user)
    return false unless can_be_resubmitted?
    
    update!(
      status: 'resubmitted',
      submitted_at: Time.current,
      submitted_by: resubmitted_by_user,
      denied_at: nil,
      denial_reason: nil
    )
    
    # Send email to manufacturer again
    send_manufacturer_notification
    
    true
  end
  
  def close!(closed_by_user)
    update!(
      status: 'closed',
      closed_at: Time.current,
      approved_by: closed_by_user
    )
  end
  
  # Public Link (for manufacturer email access - no login required)
  def public_link
    frontend_url = ENV['FRONTEND_URL'] || 'https://staging.crm.landlordinsight.com'
    "#{frontend_url}/w/#{public_token}"
  end
  
  def increment_views!
    increment!(:views_count)
  end
  
  # New methods for manufacturer view tracking
  def manufacturer_view_count
    manufacturer_claim_views.count
  end
  
  def last_viewed_at
    manufacturer_claim_views.maximum(:viewed_at)
  end
  
  # Calculations
  def parts_total
    return 0 unless parts.is_a?(Array)
    parts.sum { |p| (p['quantity'].to_f * p['cost'].to_f) }
  end
  
  def labor_total
    return 0 unless labor.is_a?(Array)
    labor.sum { |l| (l['hours'].to_f * l['rate'].to_f) }
  end
  
  def total_amount
    parts_total + labor_total
  end
  
  # Soft Delete
  def soft_delete!
    update!(is_deleted: true, deleted_at: Time.current)
  end
  
  def restore!
    update!(is_deleted: false, deleted_at: nil)
  end
  
  # Serialization
  def as_json(options = {})
    {
      id: id,
      companyId: company_id,
      locationId: location_id,
      serviceTicketId: service_ticket_id,
      manufacturerId: manufacturer_id,
      claimNumber: claim_number,
      manufacturerClaimNumber: manufacturer_claim_number,
      estimatedAmount: estimated_amount,
      approvedAmount: approved_amount,
      clientCopayAmount: client_copay_amount,
      parts: parts,
      labor: labor,
      status: status,
      submittedAt: submitted_at,
      manufacturerRespondedAt: manufacturer_responded_at,
      approvedAt: approved_at,
      deniedAt: denied_at,
      closedAt: closed_at,
      notesInternal: notes_internal,
      notesToManufacturer: notes_to_manufacturer,
      manufacturerResponse: manufacturer_response,
      denialReason: denial_reason,
      publicToken: public_token,
      publicLink: public_link,
      viewsCount: views_count,
      manufacturerViewCount: manufacturer_view_count,
      lastViewedAt: last_viewed_at,
      submittedBy: submitted_by,
      approvedBy: approved_by,
      ownerId: owner_id,
      owner: owner ? { id: owner.id, name: owner.name, email: owner.email } : nil,
      createdAt: created_at,
      updatedAt: updated_at,
      
      # Related data
      manufacturer: manufacturer ? {
        id: manufacturer.id,
        name: manufacturer.name,
        industryType: manufacturer.industry_type
      } : nil,
      
      serviceTicket: service_ticket ? {
        id: service_ticket.id,
        title: service_ticket.title,
        status: service_ticket.status
      } : nil,
      
      # Calculated values
      partsTotal: parts_total,
      laborTotal: labor_total,
      totalAmount: total_amount,
      
      # Attachment count
      attachmentsCount: attachments.count
    }
  end
  
  private
  
  def set_owner_from_service_ticket
    # Inherit owner from service ticket if not explicitly set
    if service_ticket.present? && owner_id.blank?
      self.owner_id = service_ticket.assigned_to_user&.id
    end
  end
  
  def generate_claim_number
    self.claim_number ||= loop do
      number = "WC-#{Time.current.year}-#{SecureRandom.hex(4).upcase}"
      break number unless self.class.exists?(company_id: company_id, claim_number: number)
    end
  end
  
  def generate_public_token
    self.public_token ||= loop do
      token = SecureRandom.urlsafe_base64(32)
      break token unless self.class.exists?(public_token: token)
    end
  end
  
  def create_ar_transaction_if_approved
    return unless saved_change_to_status? && approved?
    return if manufacturer_ar_transaction.present?
    
    ManufacturerArTransaction.create!(
      company_id: company_id,
      location_id: location_id,
      warranty_claim_id: id,
      manufacturer_id: manufacturer_id,
      original_claim_amount: approved_amount,
      amount_outstanding: approved_amount,
      claim_date: submitted_at&.to_date || Date.current,
      status: 'open'
    )
  end
  
  def send_manufacturer_notification
    begin
      WarrantyNotificationService.notify_manufacturer(self)
      Rails.logger.info("✅ Email sent: Warranty claim #{claim_number} submitted to #{manufacturer.name}")
    rescue WarrantyNotificationService::TemplateNotFoundError => e
      Rails.logger.error("❌ Email failed for claim #{claim_number}: #{e.message}")
      # Don't fail the submission - just log the error
    rescue WarrantyNotificationService::MissingRecipientError => e
      Rails.logger.warn("⚠️ Cannot email manufacturer for claim #{claim_number}: #{e.message}")
      # Expected when manufacturer has no email - don't fail
    rescue => e
      Rails.logger.error("❌ Unexpected error sending manufacturer notification for claim #{claim_number}: #{e.message}")
      Rails.logger.error(e.backtrace.first(5).join("\n"))
      # Don't fail the submission
    end
  end
  
  def notify_company_of_response
    begin
      WarrantyNotificationService.notify_company_on_response(self)
      Rails.logger.info("✅ Email sent: Manufacturer responded to claim #{claim_number}")
    rescue WarrantyNotificationService::TemplateNotFoundError => e
      Rails.logger.error("❌ Email failed for claim #{claim_number}: #{e.message}")
      # Don't fail the response processing
    rescue WarrantyNotificationService::MissingRecipientError => e
      Rails.logger.warn("⚠️ Cannot email company for claim #{claim_number}: #{e.message}")
      # Expected when no notification email configured
    rescue => e
      Rails.logger.error("❌ Unexpected error sending company notification for claim #{claim_number}: #{e.message}")
      Rails.logger.error(e.backtrace.first(5).join("\n"))
      # Don't fail the response
    end
  end
end
