# frozen_string_literal: true

class PurchaseOrder < ApplicationRecord
  include ActivityTrackable

  # Associations
  belongs_to :company
  belongs_to :location, optional: true
  belongs_to :supplier
  # Parallel association to the unified vendors table. supplier_id and
  # vendor_id hold identical values after the unify-vendors migration; new
  # callers should use :vendor.
  belongs_to :vendor, optional: true
  belongs_to :created_by, class_name: 'User', optional: true
  belongs_to :approved_by, class_name: 'User', optional: true
  # A factory PO (backlog E51): a home for a deal, built from its Deal Sheet.
  belongs_to :deal, optional: true
  belongs_to :deal_home_build, optional: true
  belongs_to :received_vehicle, class_name: 'Vehicle', optional: true
  # Placed with a manufacturer (its supplier record stands in for the books).
  belongs_to :manufacturer, optional: true
  
  has_many :lines, class_name: 'PurchaseOrderLine', foreign_key: 'purchase_order_id', dependent: :destroy, inverse_of: :purchase_order
  has_many :purchase_order_lines, dependent: :destroy
  has_many :parts, through: :purchase_order_lines
  has_many :inventory_transactions, through: :purchase_order_lines
  
  # CRITICAL: Enable nested attributes for line items
  accepts_nested_attributes_for :lines, allow_destroy: true
  
  # Validations
  validates :company_id, presence: true
  validates :supplier_id, presence: true
  validates :po_number, presence: true, uniqueness: { scope: [:company_id, :is_deleted], conditions: -> { where(is_deleted: [false, nil]) } }
  validates :status, presence: true, inclusion: { in: %w[draft sent partially_received received cancelled] }
  KINDS = %w[parts factory_home].freeze
  validates :kind, inclusion: { in: KINDS }
  validate :deal_is_this_companys
  validates :order_date, presence: true
  validates :subtotal, :tax_amount, :shipping_cost, :total_amount, numericality: { greater_than_or_equal_to: 0 }, allow_nil: true
  
  # Callbacks
  before_validation :set_defaults, on: :create
  before_validation :generate_po_number, on: :create
  before_save :calculate_totals
  after_save :post_to_accounting, if: :status_changed_to_received?
  
  # Scopes
  scope :active, -> { where(is_deleted: [false, nil]) }
  scope :for_current_location, -> { 
    if Current.location_filtered? && Current.location_id.present?
      # CRITICAL: Show POs assigned to this location OR not assigned to any location (All Locations)
      # This ensures "All Locations" POs (location_id IS NULL) are visible in every location
      where("location_id = ? OR location_id IS NULL", Current.location_id)
    else
      all
    end
  }
  scope :for_supplier, ->(supplier_id) { where(supplier_id: supplier_id) }
  scope :by_status, ->(status) { where(status: status) }
  scope :draft, -> { where(status: 'draft') }
  scope :sent, -> { where(status: 'sent') }
  scope :open, -> { where(status: %w[draft sent partially_received]) }
  scope :closed, -> { where(status: %w[received cancelled]) }
  scope :recent, -> { order(order_date: :desc, created_at: :desc) }
  
  # Status helpers
  def factory_home? = kind == 'factory_home'

  # The manufacturer this PO is with: set on it, or the one its supplier was
  # made for (code MFR-<id>), or the home's on its Deal Sheet.
  def contact_manufacturer
    return manufacturer if manufacturer

    id = supplier&.code.to_s[/\AMFR-(\d+)\z/, 1]
    (id && Manufacturer.find_by(id: id)) || deal_home_build&.variant&.manufacturer
  end

  # Who receives this PO by email: the manufacturer's orders contact (or its
  # rep when it has none), else the supplier's email.
  def order_contact
    if (m = contact_manufacturer)
      cm = company.company_manufacturers.find_by(manufacturer_id: m.id)
      email = cm&.effective_po_email || m.po_email.presence || m.contact_email
      name = cm&.effective_po_contact_name || m.po_contact_name || m.contact_name
      return { email: email, name: name } if email.present?
    end
    { email: supplier&.email.presence, name: supplier&.try(:contact_name) }
  end

  def draft?
    status == 'draft'
  end
  
  def sent?
    status == 'sent'
  end
  
  def partially_received?
    status == 'partially_received'
  end
  
  def received?
    status == 'received'
  end
  
  def cancelled?
    status == 'cancelled'
  end
  
  # Display methods
  def supplier_name
    supplier&.name
  end

  # The dealer's TrueBuild setting: leave prices off the factory PO it prints
  # and emails (the factory bills from its own price list).
  def hide_prices_for_factory?
    factory_home? && DealerCatalogTerm.effective(company, nil).factory_po_hide_prices == true
  end

  # The color and finish picks written onto a factory PO.
  def colors
    sheet_snapshot.to_h['colors'] || []
  end

  # The buyer on the deal this PO is for, for the PO list.
  def deal_customer_name
    deal&.customer_display_name
  end

  def deal_number
    deal&.deal_number
  end
  
  def location_name
    location&.name
  end
  
  def created_by_name
    return nil unless created_by
    "#{created_by.first_name} #{created_by.last_name}".strip
  end

  def activity_display_name
    po_number || 'PO'
  end

  def activity_module_name
    'inventory'
  end

  def activity_account_id
    nil
  end

  private
  
  def set_defaults
    self.status ||= 'draft'
    self.order_date ||= Date.current
    self.is_deleted ||= false
    self.subtotal ||= 0
    self.tax_amount ||= 0
    self.shipping_cost ||= 0
    self.total_amount ||= 0
  end
  
  def generate_po_number
    return if po_number.present?
    
    # Get the last PO number for this company
    last_po = company.purchase_orders.where.not(po_number: nil).order(po_number: :desc).first
    
    if last_po && last_po.po_number =~ /PO-(\d+)/
      next_number = $1.to_i + 1
    else
      next_number = 1
    end
    
    self.po_number = "PO-#{next_number.to_s.rjust(6, '0')}"
  end
  
  def calculate_totals
    # Ensure all lines have their line_total calculated first
    lines.each do |line|
      next if line.marked_for_destruction?
      if line.line_total.nil? || line.changed?
        subtotal = line.quantity_ordered * line.unit_cost
        discount = subtotal * ((line.discount_percent || 0) / 100.0)
        line.line_total = subtotal - discount
      end
    end
    
    # Subtotal from line items
    self.subtotal = lines.reject(&:marked_for_destruction?).sum { |l| l.line_total || 0 }
    
    # Total = subtotal + tax + shipping
    self.total_amount = subtotal + tax_amount + shipping_cost
  end

  # A factory PO posts nothing on receipt: the home's cost reaches the books
  # with the factory invoice, entered as a bill.
  def status_changed_to_received?
    !factory_home? && saved_change_to_status? && status.in?(%w[received partially_received])
  end

  def deal_is_this_companys
    errors.add(:deal, 'belongs to another company') if deal && deal.company_id != company_id
  end

  def post_to_accounting
    Accounting::PurchaseOrderPostingService.new(self).post!
  rescue => e
    Rails.logger.error("[Accounting] PO #{id} auto-post failed: #{e.message}")
  end
end
