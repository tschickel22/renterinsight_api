# frozen_string_literal: true

class PurchaseOrder < ApplicationRecord
  # Associations
  belongs_to :company
  belongs_to :location, optional: true
  belongs_to :supplier
  belongs_to :created_by, class_name: 'User', optional: true
  belongs_to :approved_by, class_name: 'User', optional: true
  
  has_many :purchase_order_lines, dependent: :destroy
  has_many :parts, through: :purchase_order_lines
  has_many :inventory_transactions, through: :purchase_order_lines
  
  # Validations
  validates :company_id, presence: true
  validates :supplier_id, presence: true
  validates :po_number, presence: true, uniqueness: { scope: [:company_id, :is_deleted], conditions: -> { where(is_deleted: false) } }
  validates :status, presence: true, inclusion: { in: %w[draft sent partially_received received closed cancelled] }
  validates :order_date, presence: true
  validates :subtotal, :tax_amount, :shipping_cost, :total_amount, numericality: { greater_than_or_equal_to: 0 }
  
  # Callbacks
  before_validation :set_defaults, on: :create
  before_validation :generate_po_number, on: :create
  before_save :calculate_totals
  after_save :update_status_based_on_lines
  
  # Scopes
  scope :active, -> { where(is_deleted: false) }
  scope :for_company, ->(company_id) { where(company_id: company_id, is_deleted: false) }
  scope :for_supplier, ->(supplier_id) { where(supplier_id: supplier_id) }
  scope :for_location, ->(location_id) { where(location_id: location_id) }
  scope :by_status, ->(status) { where(status: status) }
  scope :draft, -> { where(status: 'draft') }
  scope :sent, -> { where(status: 'sent') }
  scope :open, -> { where(status: %w[draft sent partially_received]) }
  scope :closed, -> { where(status: %w[received closed cancelled]) }
  scope :recent, -> { order(order_date: :desc, created_at: :desc) }
  scope :overdue, -> { where('expected_delivery_date < ? AND status NOT IN (?)', Date.today, %w[received closed cancelled]) }
  
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
  
  def closed?
    status == 'closed'
  end
  
  def cancelled?
    status == 'cancelled'
  end
  
  def open?
    %w[draft sent partially_received].include?(status)
  end
  
  def can_edit?
    draft?
  end
  
  def can_receive?
    sent? || partially_received?
  end
  
  def can_cancel?
    draft? || sent?
  end
  
  # Actions
  def mark_as_sent!
    return false unless draft?
    
    update!(status: 'sent', sent_at: Time.current)
  end
  
  def mark_as_received!
    return false unless all_lines_fully_received?
    
    update!(status: 'received', delivery_date: Date.today)
  end
  
  def mark_as_closed!
    update!(status: 'closed')
  end
  
  def cancel!(reason = nil)
    return false unless can_cancel?
    
    update!(status: 'cancelled', cancelled_at: Time.current, cancelled_reason: reason)
  end
  
  def soft_delete!
    update!(is_deleted: true, deleted_at: Time.current)
  end
  
  # Calculations
  def total_lines
    purchase_order_lines.count
  end
  
  def total_quantity_ordered
    purchase_order_lines.sum(:quantity_ordered)
  end
  
  def total_quantity_received
    purchase_order_lines.sum(:quantity_received)
  end
  
  def quantity_remaining
    total_quantity_ordered - total_quantity_received
  end
  
  def percent_received
    return 0 if total_quantity_ordered.zero?
    ((total_quantity_received / total_quantity_ordered) * 100).round(2)
  end
  
  def all_lines_fully_received?
    return false if purchase_order_lines.empty?
    purchase_order_lines.all? { |line| line.fully_received? }
  end
  
  def has_partial_receives?
    purchase_order_lines.any? { |line| line.quantity_received > 0 && !line.fully_received? }
  end
  
  def is_overdue?
    return false unless expected_delivery_date.present?
    return false if %w[received closed cancelled].include?(status)
    
    expected_delivery_date < Date.today
  end
  
  def days_until_delivery
    return nil unless expected_delivery_date.present?
    (expected_delivery_date - Date.today).to_i
  end
  
  # Display helpers
  def display_name
    "PO #{po_number}"
  end
  
  def supplier_name
    supplier&.name
  end
  
  def location_name
    location&.name
  end
  
  def status_badge_color
    case status
    when 'draft' then 'gray'
    when 'sent' then 'blue'
    when 'partially_received' then 'yellow'
    when 'received' then 'green'
    when 'closed' then 'gray'
    when 'cancelled' then 'red'
    else 'gray'
    end
  end
  
  def as_json(options = {})
    super(options.merge(
      only: [:id, :po_number, :status, :order_date, :expected_delivery_date, :delivery_date,
             :subtotal, :tax_amount, :shipping_cost, :total_amount, :notes, :terms,
             :tracking_number, :sent_at, :created_at, :updated_at],
      methods: [:supplier_name, :location_name, :total_lines, :total_quantity_ordered,
                :total_quantity_received, :percent_received, :is_overdue],
      include: {
        supplier: { only: [:id, :name, :code, :contact_name, :email, :phone] },
        location: { only: [:id, :name, :code] },
        created_by: { only: [:id, :first_name, :last_name] },
        purchase_order_lines: {
          include: {
            part: { only: [:id, :sku, :name, :uom] }
          }
        }
      }
    ))
  end
  
  def calculate_totals
    self.subtotal = purchase_order_lines.sum(&:line_total)
    self.total_amount = subtotal + (tax_amount || 0) + (shipping_cost || 0)
  end
  
  def update_status_based_on_lines
    return unless saved_change_to_attribute?(:id) || purchase_order_lines.any?
    
    # Don't auto-update if manually set to closed or cancelled
    return if closed? || cancelled?
    
    if all_lines_fully_received?
      update_column(:status, 'received') unless received?
    elsif has_partial_receives?
      update_column(:status, 'partially_received') unless partially_received?
    end
  end
  
  private
  
  def set_defaults
    self.order_date ||= Date.today
    self.status ||= 'draft'
    self.is_deleted = false if is_deleted.nil?
    self.subtotal ||= 0
    self.tax_amount ||= 0
    self.shipping_cost ||= 0
    self.total_amount ||= 0
  end
  
  def generate_po_number
    return if po_number.present?
    
    # Find the highest PO number for this company
    last_po = company.purchase_orders
                     .where("po_number IS NOT NULL")
                     .order(Arel.sql("CAST(SUBSTRING(po_number FROM '[0-9]+') AS INTEGER) DESC"))
                     .first
    
    if last_po&.po_number.present?
      last_num = last_po.po_number.split('-').last.to_i
      new_num = last_num + 1
      self.po_number = "PO-#{new_num.to_s.rjust(6, '0')}"
    else
      self.po_number = "PO-000001"
    end
  end
end
