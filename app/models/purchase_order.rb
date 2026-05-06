# frozen_string_literal: true

class PurchaseOrder < ApplicationRecord
  include ActivityTrackable

  # Associations
  belongs_to :company
  belongs_to :location, optional: true
  belongs_to :supplier
  belongs_to :created_by, class_name: 'User', optional: true
  belongs_to :approved_by, class_name: 'User', optional: true
  
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

  def status_changed_to_received?
    saved_change_to_status? && status.in?(%w[received partially_received])
  end

  def post_to_accounting
    Accounting::PurchaseOrderPostingService.new(self).post!
  rescue => e
    Rails.logger.error("[Accounting] PO #{id} auto-post failed: #{e.message}")
  end
end
