# frozen_string_literal: true

# One complaint on a service ticket, carrying its own parts, labor and pay
# type -- the job-line structure auto and RV DMS platforms use.
#
# Money is deliberately optional at every level. A ticket often goes out to the
# vendor with no prices, comes back with the work described and still no
# prices, and only gets numbers when the dealer prepares the invoice or the
# warranty claim. `pricing_status` tracks that progression; a nil amount means
# "not priced yet" and is never coerced to zero.
class ServiceTicketIssue < ApplicationRecord
  belongs_to :company
  belongs_to :service_ticket
  belongs_to :manufacturer, optional: true

  # Reuses the polymorphic assignment pipeline, so per-issue vendor assignment
  # inherits notification delivery tracking, resend and the review/completion
  # workflow already built for ticket-level assignment.
  has_many :contractor_assignments, as: :assignable, dependent: :destroy
  has_many :vendors, through: :contractor_assignments

  has_many_attached :attachments

  attribute :parts, :json, default: []
  attribute :labor, :json, default: []
  attribute :custom_field_values, :json, default: {}

  STATUSES = %w[open assigned in_progress awaiting_parts complete declined].freeze
  PAY_TYPES = %w[customer warranty internal].freeze
  VISIBILITIES = %w[internal external].freeze
  PRICING_STATUSES = %w[unpriced estimated final].freeze
  AUTHORIZATION_STATUSES = %w[not_required requested approved denied].freeze

  validates :title, presence: true
  validates :status, presence: true, inclusion: { in: STATUSES }
  validates :pay_type, presence: true, inclusion: { in: PAY_TYPES }
  validates :visibility, presence: true, inclusion: { in: VISIBILITIES }
  validates :pricing_status, presence: true, inclusion: { in: PRICING_STATUSES }
  validates :authorization_status, presence: true, inclusion: { in: AUTHORIZATION_STATUSES }

  scope :active, -> { where(deleted_at: nil) }
  scope :ordered, -> { order(:position, :id) }
  scope :external, -> { where(visibility: 'external') }
  scope :internal_only, -> { where(visibility: 'internal') }
  scope :warranty, -> { where(pay_type: 'warranty') }
  scope :customer_pay, -> { where(pay_type: 'customer') }
  scope :unpriced, -> { where(pricing_status: 'unpriced') }
  scope :portal_visible, -> { where(portal_visible: true) }

  before_validation :set_position, on: :create
  after_save :sync_ticket_line_items!
  after_destroy :sync_ticket_line_items!

  # ---------------------------------------------------------------- amounts

  # Actual wins over estimate once it exists; a row with neither is unpriced
  # and contributes nothing rather than silently reading as free.
  def self.effective(actual, estimate)
    return actual unless actual.nil?

    estimate
  end

  def part_rows
    coerce_rows(parts)
  end

  def labor_rows
    coerce_rows(labor)
  end

  def parts_total
    part_rows.sum { |p| row_amount(p, 'Quantity', 'UnitCost') || 0 }
  end

  def labor_total
    labor_rows.sum { |l| row_amount(l, 'Hours', 'Rate') || 0 }
  end

  def total
    parts_total + labor_total
  end

  # True when every row still lacks a usable amount -- the state a zeroed MH
  # ticket sits in while it is out with the vendor.
  def fully_unpriced?
    rows = part_rows + labor_rows
    return true if rows.empty?

    part_rows.all? { |p| row_amount(p, 'Quantity', 'UnitCost').nil? } &&
      labor_rows.all? { |l| row_amount(l, 'Hours', 'Rate').nil? }
  end

  def priced?
    pricing_status == 'final'
  end

  def billable_to_customer?
    pay_type == 'customer'
  end

  def billable_to_manufacturer?
    pay_type == 'warranty'
  end

  # ------------------------------------------------------------- visibility

  def visible_to_contractor?
    visibility == 'external'
  end

  def visible_to_customer?
    portal_visible? && visibility == 'external'
  end

  # ----------------------------------------------------------------- pre-auth

  def authorization_required?
    pay_type == 'warranty' && authorization_status != 'not_required'
  end

  def authorized?
    authorization_status == 'approved'
  end

  def soft_delete!
    update!(deleted_at: Time.current)
  end

  # Shared by ServiceTicketIssuesController and the ticket serializer so the
  # two can never drift.
  def as_api_json
    {
      id: id,
      serviceTicketId: service_ticket_id,
      position: position,
      title: title,
      complaint: complaint,
      cause: cause,
      correction: correction,
      status: status,
      payType: pay_type,
      manufacturerId: manufacturer_id,
      manufacturerName: manufacturer&.name,
      visibility: visibility,
      portalVisible: portal_visible,
      pricingStatus: pricing_status,
      laborOpCode: labor_op_code,
      authorizationNumber: authorization_number,
      authorizationStatus: authorization_status,
      requestedHours: requested_hours,
      approvedHours: approved_hours,
      approvedAmount: approved_amount,
      authorizationRequestedAt: authorization_requested_at,
      authorizationRespondedAt: authorization_responded_at,
      authorizationNotes: authorization_notes,
      vendorInvoiceNumber: vendor_invoice_number,
      vendorInvoiceAmount: vendor_invoice_amount,
      vendorInvoiceReceivedAt: vendor_invoice_received_at,
      parts: part_rows,
      labor: labor_rows,
      partsTotal: parts_total,
      laborTotal: labor_total,
      total: total,
      fullyUnpriced: fully_unpriced?,
      customFieldValues: custom_field_values,
      contractorAssignments: contractor_assignments.map do |a|
        {
          id: a.id,
          vendorId: a.vendor_id,
          vendorName: a.vendor&.name,
          status: a.status,
          assignedAt: a.assigned_at,
          reviewStatus: a.review_status
        }
      end,
      createdAt: created_at,
      updatedAt: updated_at
    }
  end

  # Flattens every issue's rows back onto the ticket's legacy `parts` / `labor`
  # arrays, tagging each with the owning issue's pay type via line_item_billing.
  # Keeping that mirror current means warranty-claim generation, invoice
  # generation and the existing detail UI need no changes while the frontend
  # migrates to issues.
  def sync_ticket_line_items!
    ticket = service_ticket
    return if ticket.nil?

    flat_parts = []
    flat_labor = []
    billing = []

    ticket.issues.reload.each do |issue|
      # 'internal' has no legacy equivalent; bill it as customer so it never
      # lands in a manufacturer claim.
      legacy_pay = issue.pay_type == 'warranty' ? 'warranty' : 'customer'

      issue.part_rows.each do |row|
        billing << {
          'index' => flat_parts.length,
          'type' => 'part',
          'billing_type' => legacy_pay,
          'manufacturer_id' => issue.manufacturer_id
        }
        flat_parts << legacy_part_row(row, issue)
      end

      issue.labor_rows.each do |row|
        billing << {
          'index' => flat_labor.length,
          'type' => 'labor',
          'billing_type' => legacy_pay,
          'manufacturer_id' => issue.manufacturer_id
        }
        flat_labor << legacy_labor_row(row, issue)
      end
    end

    # Pass the arrays, not JSON strings: ServiceTicket declares
    # `attribute :parts, :json`, and update_columns still applies that cast, so
    # pre-serializing here would encode them a second time.
    ticket.update_columns(
      parts: flat_parts,
      labor: flat_labor,
      line_item_billing: billing,
      updated_at: Time.current
    )
  end

  private

  # The legacy shape cannot express "unpriced", so nil amounts collapse to 0
  # here. That is safe because claim and invoice generation both require
  # pricing_status 'final' before they read these arrays.
  def legacy_part_row(row, issue)
    quantity = self.class.effective(row['actQuantity'], row['estQuantity'])
    unit_cost = self.class.effective(row['actUnitCost'], row['estUnitCost'])

    {
      'id' => row['id'],
      'issueId' => issue.id,
      'partNumber' => row['partNumber'],
      'description' => row['description'],
      'partId' => row['partId'],
      'quantity' => quantity.to_f,
      'unitCost' => unit_cost.to_f,
      'total' => quantity.to_f * unit_cost.to_f
    }
  end

  def legacy_labor_row(row, issue)
    hours = self.class.effective(row['actHours'], row['estHours'])
    rate = self.class.effective(row['actRate'], row['estRate'])

    {
      'id' => row['id'],
      'issueId' => issue.id,
      'description' => row['description'],
      'hours' => hours.to_f,
      'rate' => rate.to_f,
      'total' => hours.to_f * rate.to_f
    }
  end


  def set_position
    return if position.present? && position.positive?

    self.position = (service_ticket&.issues&.active&.maximum(:position) || -1) + 1
  end

  def coerce_rows(value)
    return value if value.is_a?(Array)
    return [] if value.blank?

    JSON.parse(value) rescue []
  end

  # Returns nil (not 0) when the row has not been priced, so callers can tell
  # the two apart.
  def row_amount(row, count_key, rate_key)
    count = self.class.effective(row["act#{count_key}"], row["est#{count_key}"])
    rate  = self.class.effective(row["act#{rate_key}"], row["est#{rate_key}"])
    return nil if count.nil? || rate.nil?

    count.to_f * rate.to_f
  end
end
