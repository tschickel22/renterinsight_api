# frozen_string_literal: true

# == Schema Information
#
# Table name: service_tickets
#
#  id                      :bigint           not null, primary key
#  company_id              :bigint           not null
#  account_id              :bigint
#  contact_id              :bigint
#  vehicle_id              :bigint
#  title                   :string           not null
#  description             :text             not null
#  status                  :string           not null, default("open")
#  priority                :string           not null, default("medium")
#  assigned_to             :string
#  scheduled_date          :date
#  notes                   :text
#  parts                   :jsonb            default([])
#  labor                   :jsonb            default([])
#  custom_fields           :jsonb            default({})
#  is_warranty_suspected   :boolean          default(FALSE), not null
#  is_warranty_confirmed   :boolean          default(FALSE), not null
#  warranty_claim_id       :bigint
#  created_at              :datetime         not null
#  updated_at              :datetime         not null
#

class ServiceTicket < ApplicationRecord
  include ActivityTrackable
  include LocationAware
  include NotifiableServiceTicket
  include WebhookNotifiable
  include Reportable
  include WorkflowRunCancellable

  # Workflow engine emit hooks
  after_commit :emit_workflow_created, on: :create
  after_commit :emit_workflow_updated, on: :update
  after_commit :emit_workflow_deleted, on: :destroy

  def emit_workflow_created
    WorkflowEngine.emit('service_ticket.created', self, { id: id }) if defined?(WorkflowEngine)
  end

  def emit_workflow_updated
    return unless defined?(WorkflowEngine)
    WorkflowEngine.emit('service_ticket.updated', self, { id: id, changes: saved_changes.keys })
    if self.class.column_names.include?('status') && saved_change_to_attribute?(:status)
      from, to = saved_change_to_attribute(:status)
      WorkflowEngine.emit('service_ticket.status_changed', self, { id: id, from: from, to: to })
    end
  end

  def emit_workflow_deleted
    WorkflowEngine.emit('service_ticket.deleted', self, { id: id }) if defined?(WorkflowEngine)
  end

  def self.reportable_config
    {
      label: "Service Tickets",
      category: "operations",
      fields: [
        { key: "id",                    label: "ID",                    type: "number",  filterable: true,  sortable: true  },
        { key: "ticket_number",         label: "Ticket Number",         type: "string",  filterable: true,  sortable: true  },
        { key: "title",                 label: "Title",                 type: "string",  filterable: true,  sortable: true  },
        { key: "status",                label: "Status",                type: "enum",    filterable: true,  sortable: true  },
        { key: "priority",              label: "Priority",              type: "enum",    filterable: true,  sortable: true  },
        { key: "assigned_to",           label: "Assigned To",           type: "string",  filterable: true,  sortable: true  },
        { key: "contact_id",            label: "Contact",               type: "number",  filterable: true,  sortable: true  },
        { key: "account_id",            label: "Account",               type: "number",  filterable: true,  sortable: true  },
        { key: "scheduled_date",        label: "Scheduled Date",        type: "date",    filterable: true,  sortable: true  },
        { key: "is_warranty_suspected", label: "Warranty Suspected",    type: "boolean", filterable: true,  sortable: false },
        { key: "is_warranty_confirmed", label: "Warranty Confirmed",    type: "boolean", filterable: true,  sortable: false },
        { key: "description",           label: "Description",           type: "string",  filterable: false, sortable: false },
        { key: "notes",                 label: "Notes",                 type: "string",  filterable: false, sortable: false },
        { key: "created_at",            label: "Created At",            type: "date",    filterable: true,  sortable: true  },
        { key: "updated_at",            label: "Updated At",            type: "date",    filterable: true,  sortable: true  }
      ]
    }
  end

  # Associations
  belongs_to :company
  belongs_to :location, optional: true
  belongs_to :account, optional: true
  belongs_to :contact, optional: true
  belongs_to :vehicle, optional: true
  belongs_to :deal, optional: true
  belongs_to :warranty_claim, optional: true
  belongs_to :portal_user, class_name: 'BuyerPortalAccess', optional: true
  has_one :warranty_claim_owned, -> { where(is_deleted: false) }, class_name: 'WarrantyClaim', foreign_key: :service_ticket_id, dependent: :restrict_with_error
  has_many :invoices, as: :source, dependent: :nullify
  has_many :contractor_assignments, as: :assignable, dependent: :destroy
  
  # User assignment (assigned_to stores user_id as string)
  def assigned_to_user
    return nil if assigned_to.blank?
    @assigned_to_user ||= User.find_by(id: assigned_to.to_i)
  end
  
  def assigned_to_user=(user)
    self.assigned_to = user&.id&.to_s
    @assigned_to_user = user
  end
  
  # For creator lookup
  def created_by_user
    User.find_by(id: created_by) if respond_to?(:created_by) && created_by.present?
  end
  
  # Active Storage for attachments (photos, videos, documents)
  has_many_attached :attachments
  
  # Serialize JSON columns to ensure they're always arrays
  attribute :parts, :json, default: []
  attribute :labor, :json, default: []
  attribute :custom_fields, :json, default: {}
  attribute :line_item_billing, :json, default: []
  
  # Validations
  validates :ticket_number, uniqueness: { scope: :company_id }, if: -> { ticket_number.present? }
  validates :title, presence: true
  validates :description, presence: true
  validates :status, presence: true, inclusion: { 
    in: %w[pending_review open in_progress waiting_on_manufacturer waiting_parts completed cancelled] 
  }
  validates :priority, presence: true, inclusion: { 
    in: %w[low medium high urgent] 
  }
  
  # Scopes
  scope :pending_review, -> { where(status: 'pending_review') }
  scope :open, -> { where(status: 'open') }
  scope :in_progress, -> { where(status: 'in_progress') }
  scope :waiting_on_manufacturer, -> { where(status: 'waiting_on_manufacturer') }
  scope :completed, -> { where(status: 'completed') }
  scope :by_priority, ->(priority) { where(priority: priority) }
  scope :assigned_to, ->(assignee) { where(assigned_to: assignee) }
  scope :scheduled_between, ->(start_date, end_date) { where(scheduled_date: start_date..end_date) }
  scope :recent, -> { order(created_at: :desc) }
  scope :warranty_suspected, -> { where(is_warranty_suspected: true) }
  scope :warranty_confirmed, -> { where(is_warranty_confirmed: true) }
  scope :with_warranty_claims, -> { where.not(warranty_claim_id: nil) }
  scope :portal_created, -> { where(is_portal_created: true) }
  
  # Callbacks
  before_validation :generate_ticket_number, on: :create
  before_validation :set_defaults
  before_validation :normalize_assigned_to
  
  # Instance methods
  def parts_total
    parts_array = parts.is_a?(Array) ? parts : (parts.present? ? (JSON.parse(parts) rescue []) : [])
    parts_array.sum { |p| p['total'].to_f }
  end
  
  def labor_total
    labor_array = labor.is_a?(Array) ? labor : (labor.present? ? (JSON.parse(labor) rescue []) : [])
    labor_array.sum { |l| l['total'].to_f }
  end
  
  def total_cost
    parts_total + labor_total
  end
  
  def overdue?
    scheduled_date && scheduled_date < Date.today && status != 'completed'
  end
  
  # Warranty Methods
  def has_warranty_claim?
    warranty_claim_owned.present?
  end
  
  def warranty_status
    return nil unless has_warranty_claim?
    warranty_claim_owned.status
  end
  
  def mark_warranty_suspected!
    update!(is_warranty_suspected: true)
  end
  
  def confirm_warranty!
    update!(is_warranty_confirmed: true)
  end
  
  def create_warranty_claim!(manufacturer_id:, estimated_amount: nil, parts: nil, labor: nil, notes: nil, submitted_by:)
    raise 'Warranty claim already exists' if has_warranty_claim?
    
    claim = WarrantyClaim.create!(
      company_id: company_id,
      location_id: location_id,
      service_ticket_id: id,
      manufacturer_id: manufacturer_id,
      estimated_amount: estimated_amount || total_cost,
      parts: parts || self.parts,
      labor: labor || self.labor,
      notes_to_manufacturer: notes,
      submitted_by: submitted_by,
      status: 'draft'
    )
    
    update!(
      warranty_claim_id: claim.id,
      is_warranty_confirmed: true,
      status: 'waiting_on_manufacturer'
    )
    
    claim
  end

  # Idempotent: mark this ticket as a warranty claim and ensure a SINGLE draft
  # WarrantyClaim exists. Requires a manufacturer. Does NOT generate an invoice
  # and does NOT change ticket status (status flips to waiting_on_manufacturer
  # only at submit time). Safe to call repeatedly: returns the existing claim if
  # one is already present (updating its manufacturer while still draft).
  def mark_as_warranty!(manufacturer_id:, marked_by:)
    # Fresh query — never trust a cached association (a prior un-mark in the same
    # instance may have soft-deleted the old claim).
    existing = WarrantyClaim.where(service_ticket_id: id, is_deleted: false).first
    if existing
      if existing.draft? && existing.manufacturer_id != manufacturer_id.to_i
        existing.update!(manufacturer_id: manufacturer_id)
      end
      update!(warranty_claim_id: existing.id, is_warranty_confirmed: true)
      association(:warranty_claim_owned).reset
      return existing
    end

    claim = WarrantyClaim.create!(
      company_id: company_id,
      location_id: location_id,
      service_ticket_id: id,
      manufacturer_id: manufacturer_id,
      estimated_amount: 0,
      parts: [],
      labor: [],
      submitted_by: marked_by,
      status: 'draft'
    )

    update!(warranty_claim_id: claim.id, is_warranty_confirmed: true)
    association(:warranty_claim_owned).reset
    claim
  end

  # Gated un-mark. Only permitted while the claim is draft AND its warranty
  # invoice (if any) is still draft. Cascades: destroys the draft warranty
  # invoice + items, soft-deletes the draft claim, clears the ticket's warranty
  # flags/link. Returns [:ok] on success or [:blocked, reason] if not permitted.
  def unmark_warranty!
    # Fresh query — never trust a cached association.
    claim = WarrantyClaim.where(service_ticket_id: id, is_deleted: false).first
    unless claim
      update!(warranty_claim_id: nil, is_warranty_confirmed: false, is_warranty_suspected: false)
      association(:warranty_claim_owned).reset
      return [:ok]
    end

    return [:blocked, 'Claim has already been submitted to the manufacturer'] unless claim.draft?

    warranty_invoice = Invoice.where(source_type: 'WarrantyClaim', source_id: claim.id).first
    if warranty_invoice && warranty_invoice.status != 'draft'
      return [:blocked, 'Warranty invoice has been finalized/sent — remove it explicitly first']
    end

    transaction do
      warranty_invoice&.destroy!            # cascades invoice_items via dependent: :destroy
      claim.soft_delete!                    # is_deleted: true; partial unique index frees the ticket
      update!(warranty_claim_id: nil, is_warranty_confirmed: false, is_warranty_suspected: false)
    end
    association(:warranty_claim_owned).reset
    [:ok]
  end
  
  # Line Item Billing Methods
  def set_line_billing(index:, type:, billing_type:, manufacturer_id: nil)
    # Parse line_item_billing if it's a string from DB
    Rails.logger.info "🛠️ [Model set_line_billing] START - Raw line_item_billing: #{line_item_billing.inspect}"
    
    billing_data = line_item_billing.is_a?(Array) ? line_item_billing : (JSON.parse(line_item_billing) rescue [])
    billing_data ||= []
    
    Rails.logger.info "🛠️ [Model set_line_billing] Parsed billing_data: #{billing_data.to_json}"
    Rails.logger.info "🛠️ [Model set_line_billing] Setting: index=#{index}, type=#{type}, billing_type=#{billing_type}, manufacturer_id=#{manufacturer_id}"
    
    # Remove old entry for this index+type
    Rails.logger.info "🛠️ [Model set_line_billing] BEFORE reject!: #{billing_data.to_json}"
    billing_data.reject! { |item| item['index'] == index && item['type'] == type }
    Rails.logger.info "🛠️ [Model set_line_billing] AFTER reject!: #{billing_data.to_json}"
    
    # Add new entry
    new_entry = {
      'index' => index,
      'type' => type,
      'billing_type' => billing_type,
      'manufacturer_id' => manufacturer_id
    }
    new_entry.delete('manufacturer_id') if manufacturer_id.nil?
    
    Rails.logger.info "🛠️ [Model set_line_billing] New entry: #{new_entry.to_json}"
    
    billing_data << new_entry
    
    Rails.logger.info "🛠️ [Model set_line_billing] Final billing_data BEFORE update!: #{billing_data.to_json}"
    
    update!(line_item_billing: billing_data)

    # Keep the draft warranty claim's parts/labor/amount in sync with the
    # currently warranty-tagged lines (no "Generate" step required).
    resync_draft_claim!
  end
  
  def get_line_billing(index:, type:)
    return 'customer' unless line_item_billing.present?
    
    # Parse if it's a JSON string
    billing_data = line_item_billing.is_a?(Array) ? line_item_billing : (JSON.parse(line_item_billing) rescue [])
    
    item = billing_data.find { |i| i['index'] == index && i['type'] == type }
    item&.dig('billing_type') || 'customer'
  end
  
  def warranty_parts
    return [] unless parts.is_a?(Array)
    
    # Parse line_item_billing if needed
    billing_data = line_item_billing.is_a?(Array) ? line_item_billing : (JSON.parse(line_item_billing || '[]') rescue [])
    
    Rails.logger.info "🔍 [warranty_parts] line_item_billing: #{billing_data.to_json}"
    Rails.logger.info "🔍 [warranty_parts] parts count: #{parts.length}"
    
    return [] if billing_data.blank?
    
    result = parts.each_with_index.select do |part, index|
      billing_type = get_line_billing(index: index, type: 'part')
      Rails.logger.info "🔍 [warranty_parts] Part #{index}: billing_type=#{billing_type}"
      billing_type == 'warranty'
    end.map(&:first)
    
    Rails.logger.info "🔍 [warranty_parts] RESULT: #{result.to_json}"
    result
  end
  
  def customer_parts
    return [] unless parts.is_a?(Array)
    
    # Parse line_item_billing if needed
    billing_data = line_item_billing.is_a?(Array) ? line_item_billing : (JSON.parse(line_item_billing || '[]') rescue [])
    
    Rails.logger.info "🔍 [customer_parts] line_item_billing: #{billing_data.to_json}"
    Rails.logger.info "🔍 [customer_parts] parts count: #{parts.length}"
    
    return parts if billing_data.blank?
    
    result = parts.each_with_index.reject do |part, index|
      billing_type = get_line_billing(index: index, type: 'part')
      Rails.logger.info "🔍 [customer_parts] Part #{index}: billing_type=#{billing_type}"
      billing_type == 'warranty'
    end.map(&:first)
    
    Rails.logger.info "🔍 [customer_parts] RESULT: #{result.to_json}"
    result
  end
  
  def warranty_labor
    return [] unless labor.is_a?(Array)
    
    # Parse line_item_billing if needed
    billing_data = line_item_billing.is_a?(Array) ? line_item_billing : (JSON.parse(line_item_billing || '[]') rescue [])
    
    Rails.logger.info "🔍 [warranty_labor] line_item_billing: #{billing_data.to_json}"
    Rails.logger.info "🔍 [warranty_labor] labor count: #{labor.length}"
    
    return [] if billing_data.blank?
    
    result = labor.each_with_index.select do |item, index|
      billing_type = get_line_billing(index: index, type: 'labor')
      Rails.logger.info "🔍 [warranty_labor] Labor #{index}: billing_type=#{billing_type}"
      billing_type == 'warranty'
    end.map(&:first)
    
    Rails.logger.info "🔍 [warranty_labor] RESULT: #{result.to_json}"
    result
  end
  
  def customer_labor
    return [] unless labor.is_a?(Array)
    
    # Parse line_item_billing if needed
    billing_data = line_item_billing.is_a?(Array) ? line_item_billing : (JSON.parse(line_item_billing || '[]') rescue [])
    
    Rails.logger.info "🔍 [customer_labor] line_item_billing: #{billing_data.to_json}"
    Rails.logger.info "🔍 [customer_labor] labor count: #{labor.length}"
    
    return labor if billing_data.blank?
    
    result = labor.each_with_index.reject do |item, index|
      billing_type = get_line_billing(index: index, type: 'labor')
      Rails.logger.info "🔍 [customer_labor] Labor #{index}: billing_type=#{billing_type}"
      billing_type == 'warranty'
    end.map(&:first)
    
    Rails.logger.info "🔍 [customer_labor] RESULT: #{result.to_json}"
    result
  end
  
  def has_warranty_items?
    warranty_parts.any? || warranty_labor.any?
  end
  
  def has_customer_items?
    customer_parts.any? || customer_labor.any?
  end
  
  def warranty_total
    parts_total = warranty_parts.sum { |p| (p['quantity'].to_f * p['unitCost'].to_f) }
    labor_total = warranty_labor.sum { |l| (l['hours'].to_f * l['rate'].to_f) }
    parts_total + labor_total
  end
  
  def customer_total
    parts_total = customer_parts.sum { |p| (p['quantity'].to_f * p['unitCost'].to_f) }
    labor_total = customer_labor.sum { |l| (l['hours'].to_f * l['rate'].to_f) }
    parts_total + labor_total
  end
  
  private
  
  # Re-sync the draft warranty claim's line items + estimate from the ticket's
  # currently warranty-tagged parts/labor. Draft-only: never mutates a claim that
  # has been submitted (its contents are locked to what the manufacturer received).
  # Mirrors what generate_warranty_claim copies so the two stay consistent.
  def resync_draft_claim!
    claim = WarrantyClaim.where(service_ticket_id: id, is_deleted: false).first
    return unless claim&.draft?

    claim.update!(
      parts: warranty_parts,
      labor: warranty_labor,
      estimated_amount: warranty_total
    )
  rescue => e
    Rails.logger.error "[resync_draft_claim!] ticket #{id}: #{e.message}"
  end
  
  def generate_ticket_number
    return if ticket_number.present?
    
    # Generate ticket number format: ST-YYYYMMDD-NNNN
    # Example: ST-20260121-0001
    date_part = Date.today.strftime('%Y%m%d')
    
    # Find the highest ticket number for today
    last_ticket = company.service_tickets
                         .where("ticket_number LIKE ?", "ST-#{date_part}-%")
                         .order(ticket_number: :desc)
                         .first
    
    if last_ticket && last_ticket.ticket_number =~ /ST-\d{8}-(\d{4})$/
      sequence = $1.to_i + 1
    else
      sequence = 1
    end
    
    self.ticket_number = "ST-#{date_part}-#{sequence.to_s.rjust(4, '0')}"
  end
  
  def set_defaults
    self.status ||= 'open'
    self.priority ||= 'medium'
    self.parts ||= []
    self.labor ||= []
    self.custom_fields ||= {}
    self.line_item_billing ||= []
  end
  
  def normalize_assigned_to
    # Convert integer to string for database storage
    # assigned_to column is STRING, but frontend may send integer
    if assigned_to.present? && !assigned_to.is_a?(String)
      self.assigned_to = assigned_to.to_s
    end
    
    # Don't allow empty string for status - use nil instead (will trigger default)
    if status.blank?
      self.status = nil
    end
  end

  # ActivityTrackable overrides
  def activity_display_name
    try(:ticket_number) || try(:title) || "Ticket ##{id}"
  end

  def activity_module_name
    'service'
  end

  def activity_account_id
    try(:account_id) || contact&.try(:account_id)
  end
end
